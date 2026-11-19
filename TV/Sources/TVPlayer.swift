import AVFoundation
import MediaPlayer
import UIKit
import os
import CoreImage
import SwiftUI

/// A queue of songs streamed through the Mac, played the way Tide on the Mac plays
/// them: its smart transitions (the Mac plans each mix, the TV plays it on two
/// players), smooth fades on pause and skip, loudness matching, and Autoplay or the
/// AI DJ's mood when the queue runs out. Follows the Mac's playback settings.
@MainActor @Observable final class TVPlayer {
    private(set) var queue: [Song] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var time: TimeInterval = 0
    private(set) var error: String?
    /// The AI DJ's request while its songs fill Up Next, and one being looked up.
    private(set) var mood: String?
    private(set) var moodLoading: String?

    /// Counts songs you started yourself (not ones that simply followed), so the app can show Now Playing.
    private(set) var started = 0

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Song] { queue.indices.contains(index) ? Array(queue[(index + 1)...]) : [] }
    var duration: TimeInterval {
        let d = player.currentItem?.duration.seconds ?? .nan
        return d.isFinite && d > 0 ? d : current?.playDuration ?? 0
    }

    static let log = Logger(subsystem: "local.tide.tv", category: "transitions")
    @ObservationIgnored private let link: MacLink
    @ObservationIgnored private let players = [AVPlayer(), AVPlayer()]
    /// Which player is heard (and seen, for videos); the other one mixes in the next song.
    private var active = 0
    private var player: AVPlayer { players[active] }
    var visiblePlayer: AVPlayer { players[active] }

    /// Music videos instead of just the sound, for songs that have one (like the Mac's Song | Video).
    private(set) var videoMode = UserDefaults.standard.bool(forKey: "video")
    var showsVideo: Bool { videoMode && current?.hasVideo == true }
    /// The playing video's own colours, sampled every two seconds, for the background.
    private(set) var videoColors: [Color]?
    @ObservationIgnored private var lastSample = Date.distantPast
    @ObservationIgnored private let sampler = CIContext(options: [.useSoftwareRenderer: false])
    @ObservationIgnored private var settings = TVProtocol.Settings(smart: false, smooth: true, crossfade: 0, gapless: true,
                                                                 matchLoudness: true)
    /// Loudness matching, per player (YouTube's own turn-down, never up).
    @ObservationIgnored private var gains = [1.0, 1.0]
    /// Smooth fades on pause, play and skip: the level now, and where it is heading.
    @ObservationIgnored private var level = 1.0
    @ObservationIgnored private var levelRamp: (from: Double, to: Double, start: Date, seconds: Double, then: (() -> Void)?)?
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var seekTarget: TimeInterval?
    @ObservationIgnored private var retriedLoad = false

    // Transitions: the plan for "current>next", the next song waiting on the other
    // player at its first beat, and the mix under way.
    @ObservationIgnored private var plan: (key: String, mix: TVProtocol.Mix)?
    @ObservationIgnored private var planning: String?
    @ObservationIgnored private var prepared: (key: String, stage: Stage)?
    private enum Stage { case loading, parking, ready }
    @ObservationIgnored private var bending = false
    @ObservationIgnored private var mixing: Mixing?
    private struct Mixing {
        let outgoing: Int
        let start: Date
        let seconds: TimeInterval
        let rise: TimeInterval
        let fall: TimeInterval
        let hold: Double
        let early: Bool
        let gentle: Bool
        let incomingSpeed: Double
        let outgoingLevel: Double
    }

    @ObservationIgnored private var moodPool: [Song] = []
    @ObservationIgnored private var fetchingMore = false

    init(link: MacLink) {
        self.link = link
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        for p in players { p.automaticallyWaitsToMinimizeStalling = false }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                               queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem, self.mixing == nil else { return }
                self.advance()
            }
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    // MARK: Controls

    func play(_ songs: [Song], at start: Int = 0) {
        guard songs.indices.contains(start) else { return }
        endMood()
        queue = songs
        index = start
        started += 1
        load()
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        cancelMix()
        rampLevel(to: 0, over: settings.smooth ? 0.35 : 0) { [weak self] in self?.player.pause() }
        updateNowPlaying()
    }

    func resume() {
        guard current != nil, !isPlaying else { return }
        if player.currentItem == nil { return load() }
        isPlaying = true
        player.play()
        rampLevel(to: 1, over: settings.smooth ? 0.35 : 0)
        updateNowPlaying()
    }

    func next() {
        guard index + 1 < queue.count else { Task { await refill(thenAdvance: true) }; return }
        skip { $0.index += 1 }
    }

    /// Back to the start of the song, or to the one before when near its start.
    func previous() {
        if time > 3 || index == 0 {
            cancelMix()
            player.seek(to: .zero)
        } else {
            skip { $0.index -= 1 }
        }
    }

    /// Jumps within the song; a mix that was planned is planned again from there.
    /// Quick presses add up from where the last one was going, and the bar stays
    /// there until the player has arrived (it reports the old place until then).
    /// The sound dips out and back in around the jump, so it doesn't cut.
    func seek(by seconds: TimeInterval) {
        guard current != nil else { return }
        cancelMix()
        let target = min(max(0, (seekTarget ?? time) + seconds), max(0, duration - 1))
        seekTarget = target
        time = target
        let jump = { [weak self] in
            guard let self, self.seekTarget == target else { return }
            // A little leeway starts the sound sooner than an exact seek does.
            let leeway = CMTime(seconds: 0.25, preferredTimescale: 1000)
            self.player.seek(to: CMTime(seconds: target, preferredTimescale: 44100),
                             toleranceBefore: leeway, toleranceAfter: leeway) { done in
                Task { @MainActor in
                    guard done, self.seekTarget == target else { return }
                    self.seekTarget = nil
                    if self.isPlaying { self.rampLevel(to: 1, over: 0.3) }
                }
            }
        }
        if isPlaying {
            rampLevel(to: 0, over: 0.1, then: jump)
        } else {
            jump()
        }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        skip { $0.index = i }
    }

    /// A skip fades the playing song out first when smooth transitions are on.
    private func skip(_ change: @escaping (TVPlayer) -> Void) {
        cancelMix()
        if isPlaying, settings.smooth {
            rampLevel(to: 0, over: 0.25) { [weak self] in
                guard let self else { return }
                change(self)
                self.load()
            }
        } else {
            change(self)
            load()
        }
    }

    // MARK: Loading

    private func url(for song: Song) -> URL? {
        videoMode && song.hasVideo ? link.videoURL(song.id) : link.audioURL(song.id)
    }

    /// Switches between the song and its video at the same place in it.
    func setVideo(_ on: Bool) {
        guard on != videoMode else { return }
        videoMode = on
        UserDefaults.standard.set(on, forKey: "video")
        guard let song = current, song.hasVideo else { return }
        let at = time
        load(rise: true, at: at)
    }

    /// - Parameter rise: fade in (a song you picked); false when it simply follows the last.
    /// - Parameter at: where to start, when switching between song and video.
    private func load(rise: Bool = true, at start: TimeInterval = 0, retry: Bool = false) {
        guard let song = current, let url = url(for: song) else { return }
        if !retry { retriedLoad = false }
        loadToken += 1
        let token = loadToken
        cancelMix()
        players[1 - active].replaceCurrentItem(with: nil)
        error = nil
        time = 0
        seekTarget = nil
        player.replaceCurrentItem(with: item(url))
        if start > 0 {
            seekTarget = start
            time = start
            player.seek(to: CMTime(seconds: start, preferredTimescale: 44100)) { [weak self] _ in
                Task { @MainActor in self?.seekTarget = nil }
            }
        }
        player.rate = 1
        isPlaying = true
        let fade = rise && settings.smooth
        level = fade ? 0 : 1
        levelRamp = nil
        applyVolumes()
        player.play()
        if fade { rampLevel(to: 1, over: 0.35) }
        updateNowPlaying()
        let slot = active
        Task {
            await refreshSettings()
            await loadGain(song.id, into: slot, token: token)
        }
        afterSongStarted()
    }

    private func item(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        if url.path.contains("/video/") {
            item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]))
        }
        // Keeps the pitch when a beat-matched mix bends the tempo.
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    /// The song ended with no transition planned: the next one starts at full.
    private func advance() {
        guard index + 1 < queue.count else { Task { await refill(thenAdvance: true) }; return }
        index += 1
        load(rise: false)
    }

    private func afterSongStarted() {
        if let following = upNext.first { link.warm(following.id, video: videoMode && following.hasVideo) }
        if upNext.count < 2 { Task { await refill(thenAdvance: false) } }
    }

    private func refreshSettings() async {
        if let fresh: TVProtocol.Settings = try? await link.get("settings") { settings = fresh }
    }

    private func loadGain(_ id: String, into slot: Int, token: Int) async {
        guard settings.matchLoudness, let db: Double = try? await link.get("gain/" + id) else {
            gains[slot] = 1
            return
        }
        // The song on that player changed meanwhile.
        guard slot != active || token == loadToken else { return }
        gains[slot] = pow(10, db / 20)
    }

    // MARK: The clock

    private func update() {
        let t = player.currentTime().seconds
        time = seekTarget ?? (t.isFinite ? t : 0)
        if player.currentItem?.status == .failed {
            if !retriedLoad {
                // Most often Tide on the Mac restarted on a new port: find it, then pick up where it was.
                retriedLoad = true
                let at = time
                player.replaceCurrentItem(with: nil)
                Task {
                    if await link.reconnect() { load(rise: false, at: at, retry: true) } else { error = "Can't reach Tide on the Mac" }
                }
            } else {
                error = player.currentItem?.error?.localizedDescription ?? "Couldn't play this song"
                isPlaying = false
            }
        }
        if let ramp = levelRamp {
            let p = ramp.seconds <= 0 ? 1 : min(1, Date().timeIntervalSince(ramp.start) / ramp.seconds)
            level = ramp.from + (ramp.to - ramp.from) * p
            if p >= 1 {
                levelRamp = nil
                ramp.then?()
            }
        }
        if isPlaying, mixing == nil {
            planIfDue()
            prepareIfDue()
            bendIfDue()
            startIfDue()
        }
        if let m = mixing { runMix(m) }
        applyVolumes()
        sampleVideoColors()
    }

    private func sampleVideoColors() {
        guard showsVideo else {
            if videoColors != nil { videoColors = nil }
            return
        }
        guard Date().timeIntervalSince(lastSample) >= 2,
              let output = player.currentItem?.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first else { return }
        lastSample = Date()
        let at = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: at, itemTimeForDisplay: nil) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let small = image.transformed(by: CGAffineTransform(scaleX: 48 / image.extent.width, y: 48 / image.extent.height))
        guard let frame = sampler.createCGImage(small, from: small.extent) else { return }
        let found = CoverColors.palette(frame)
        if !found.isEmpty { videoColors = found }
    }

    private func applyVolumes() {
        let mixLevels = mixing.map(levels) ?? (incoming: 1, outgoing: 0)
        for slot in 0..<2 {
            if slot == active {
                players[slot].volume = Float(level * gains[slot] * mixLevels.incoming)
            } else if let m = mixing, slot == m.outgoing {
                players[slot].volume = Float(gains[slot] * mixLevels.outgoing)
            } else {
                players[slot].volume = 0
            }
        }
    }

    private func rampLevel(to target: Double, over seconds: Double, then done: (() -> Void)? = nil) {
        guard seconds > 0 else {
            level = target
            levelRamp = nil
            applyVolumes()
            done?()
            return
        }
        levelRamp = (level, target, Date(), seconds, done)
    }

    // MARK: Transitions (the Mac's plan, played here)

    private var nextSong: Song? { index + 1 < queue.count ? queue[index + 1] : nil }
    private var key: String? { current.flatMap { a in nextSong.map { a.id + ">" + $0.id } } }

    /// 100 s before the end, like the Mac: asks it for the mix into the next song.
    private func planIfDue() {
        guard let key, plan?.key != key, planning != key, let a = current, let b = nextSong else { return }
        let length = duration
        guard length > 30, time >= length - 100 else { return }
        if !settings.smart {
            if settings.crossfade > 0 {
                plan = (key, mix(outAt: length - settings.crossfade, fade: settings.crossfade))
            } else if settings.gapless {
                plan = (key, mix(outAt: max(0, length - 0.05), fade: 0))
            }
            return
        }
        planning = key
        Task {
            let found: TVProtocol.Mix? = try? await link.get("plan", [
                URLQueryItem(name: "from", value: a.id), URLQueryItem(name: "to", value: b.id),
                URLQueryItem(name: "length", value: String(length)),
            ])
            guard planning == key else { return }
            planning = nil
            // No plan (the Mac couldn't listen): a plain five-second crossfade.
            plan = (key, found ?? mix(outAt: length - 5, fade: 5))
        }
    }

    private func mix(outAt: TimeInterval, fade: TimeInterval) -> TVProtocol.Mix {
        TVProtocol.Mix(outAt: outAt, inAt: 0, fade: fade, onBeat: false, matched: false, speed: 1, incomingSpeed: 1,
                       beat: 0, swapDelay: nil, swapsBass: false, ringOut: 0, layered: false)
    }

    /// Eight seconds ahead, loads the next song on the other player; once it's ready,
    /// parks it at its first beat (seek, then preroll, which throws on an unready item).
    private func prepareIfDue() {
        guard let key, let plan, plan.key == key, time >= plan.mix.outAt - 8, let b = nextSong else { return }
        let slot = 1 - active
        let incoming = players[slot]
        if prepared?.key != key {
            guard let url = url(for: b) else { return }
            prepared = (key, .loading)
            incoming.volume = 0
            incoming.replaceCurrentItem(with: item(url))
            let token = loadToken
            Task { await loadGain(b.id, into: slot, token: token) }
            return
        }
        guard prepared?.stage == .loading, incoming.currentItem?.status == .readyToPlay, incoming.status == .readyToPlay
        else { return }
        prepared?.stage = .parking
        let rate = Float(plan.mix.matched ? plan.mix.incomingSpeed : 1)
        incoming.seek(to: CMTime(seconds: plan.mix.inAt, preferredTimescale: 44100),
                      toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor in
                guard let self, self.prepared?.key == key, done else { return }
                guard incoming.status == .readyToPlay, incoming.rate == 0 else {
                    self.prepared?.stage = .ready
                    return
                }
                incoming.preroll(atRate: rate) { _ in
                    Task { @MainActor in
                        guard self.prepared?.key == key else { return }
                        self.prepared?.stage = .ready
                    }
                }
            }
        }
    }

    /// The song that's leaving bends to the new one's tempo over the last four seconds.
    private func bendIfDue() {
        guard let plan, plan.key == key, plan.mix.matched, time >= plan.mix.outAt - 4 else { return }
        let target = 1 / plan.mix.speed
        let p = min(1, max(0, (time - (plan.mix.outAt - 4)) / 4))
        player.rate = Float(1 + (target - 1) * p)
        bending = true
    }

    /// Within half a second of the planned beat, starts the next song on the host clock,
    /// so it lands on that beat rather than whenever the next tick comes.
    private func startIfDue() {
        guard let key, let plan, plan.key == key, prepared?.key == key, prepared?.stage == .ready,
              time >= plan.mix.outAt - 0.5 else { return }
        let m = plan.mix
        let slot = 1 - active
        let rate = Double(max(0.25, player.rate))
        let wait = max(0, (m.outAt - time) / rate)
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        players[slot].setRate(Float(m.matched ? m.incomingSpeed : 1), time: CMTime(seconds: m.inAt, preferredTimescale: 44100),
                              atHostTime: CMTimeAdd(host, CMTime(seconds: wait, preferredTimescale: 1_000_000)))
        // The Mac's mix shape (Player.startPrepared), in real seconds.
        let seconds = m.matched ? m.fade * m.speed : m.fade
        let ownTime = m.matched ? m.speed : 1
        let hold = m.matched && m.swapsBass && seconds > 0.05
            ? min(0.8, (m.swapDelay.map { $0 * ownTime } ?? seconds / 2) / seconds) : 0
        let long = hold > 0 && seconds >= 12 && m.layered
        mixing = Mixing(outgoing: active, start: Date().addingTimeInterval(wait), seconds: seconds,
                        rise: long ? seconds * max(hold, 0.3) : seconds, fall: seconds + m.ringOut * ownTime,
                        hold: hold, early: long, gentle: long, incomingSpeed: m.matched ? m.incomingSpeed : 1,
                        outgoingLevel: level)
        // How far apart the two songs' beats really landed, as the Mac logs it.
        let old = players[active], new = players[slot]
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 1) {
            let a = old.currentTime().seconds, b = new.currentTime().seconds
            let offset = ((a - m.outAt) * (m.matched ? m.speed : 1) - (b - m.inAt) / (m.matched ? m.incomingSpeed : 1)) * 1000
            Self.log.info("mix started, beats \(offset, format: .fixed(precision: 0)) ms apart, fade \(m.fade, format: .fixed(precision: 1)) s, matched \(m.matched)")
        }
        prepared = nil
        self.plan = nil
        bending = false
        seekTarget = nil
        active = slot
        index += 1
        level = 1
        levelRamp = nil
        updateNowPlaying()
        afterSongStarted()
        Task { await refreshSettings() }
    }

    /// Equal-power curves, as on the Mac: the new song rises, the old one holds (in a
    /// beat-matched mix, until the swap point) and then falls under it.
    private func levels(_ m: Mixing) -> (incoming: Double, outgoing: Double) {
        let elapsed = Date().timeIntervalSince(m.start)
        guard elapsed >= 0 else { return (0, m.outgoingLevel) }
        func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        let rise = m.rise <= 0.05 ? 1 : min(1, elapsed / m.rise)
        let incoming = m.early ? sin(rise * .pi / 2) : sin(smoothstep(rise) * .pi / 2)
        let fall = m.fall <= 0.05 ? 1 : min(1, elapsed / m.fall)
        let q = min(1, max(0, (fall - m.hold) / max(0.05, 1 - m.hold)))
        let outgoing = cos((m.gentle ? q : smoothstep(q)) * .pi / 2) * m.outgoingLevel
        return (incoming, outgoing)
    }

    private func runMix(_ m: Mixing) {
        let elapsed = Date().timeIntervalSince(m.start)
        // The new song's own tempo comes back slowly once it plays alone.
        if m.incomingSpeed != 1, elapsed > m.seconds {
            let p = min(1, (elapsed - m.seconds) / 8)
            player.rate = Float(m.incomingSpeed + (1 - m.incomingSpeed) * p)
        }
        if elapsed >= max(m.fall, m.seconds + (m.incomingSpeed != 1 ? 8 : 0)) {
            let old = players[m.outgoing]
            old.pause()
            old.replaceCurrentItem(with: nil)
            mixing = nil
        }
    }

    /// A skip or pause during a planned mix drops it; the other player goes quiet.
    private func cancelMix() {
        if let m = mixing {
            players[m.outgoing].pause()
            players[m.outgoing].replaceCurrentItem(with: nil)
            mixing = nil
        }
        if prepared != nil {
            players[1 - active].replaceCurrentItem(with: nil)
            prepared = nil
        }
        if bending {
            player.rate = isPlaying ? 1 : 0
            bending = false
        }
        plan = nil
        planning = nil
    }

    // MARK: Queue

    /// Plays the song with YouTube Music's radio for it after (Autoplay fills it in).
    func startRadio(_ song: Song) {
        play([song])
    }

    /// Keeps the playing song going and replaces Up Next with its radio.
    func startRadioFromCurrent() {
        guard let song = current else { return }
        cancelMix()
        endMood()
        queue = [song]
        index = 0
        Task { await refill(thenAdvance: false) }
    }

    func playNext(_ song: Song) {
        guard current != nil else { return play([song]) }
        cancelMix()
        queue.insert(song, at: index + 1)
    }

    func addToQueue(_ song: Song) {
        guard current != nil else { return play([song]) }
        cancelMix()
        queue.append(song)
    }

    // MARK: Autoplay and the AI DJ

    /// Replaces Up Next with the AI DJ's songs for `prompt` and keeps it going from there.
    func startMood(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        moodLoading = prompt
        Task {
            let songs: [Song] = (try? await link.get("mood", [URLQueryItem(name: "q", value: prompt)])) ?? []
            guard moodLoading == prompt else { return }
            moodLoading = nil
            guard !songs.isEmpty else { return }
            let batch = Array(songs.prefix(10))
            if current == nil || !isPlaying {
                queue = batch
                index = 0
                started += 1
                load()
            } else {
                cancelMix()
                queue = Array(queue[...index]) + batch.filter { $0.id != current?.id }
            }
            mood = prompt
            moodPool = Array(songs.dropFirst(10))
        }
    }

    func endMood() {
        mood = nil
        moodLoading = nil
        moodPool = []
    }

    /// Tops up Up Next: from the mood's songs while one is on, then from YouTube's radio.
    private func refill(thenAdvance: Bool) async {
        guard !fetchingMore, let last = queue.last else { return }
        fetchingMore = true
        defer { fetchingMore = false }
        let known = Set(queue.map(\.id))
        var more = moodPool.prefix(10).filter { !known.contains($0.id) }
        moodPool.removeFirst(min(10, moodPool.count))
        if more.isEmpty {
            let seed = mood != nil ? (queue.suffix(10).randomElement() ?? last) : last
            more = ((try? await link.get("radio/" + seed.id)) ?? [Song]()).filter { !known.contains($0.id) }
        }
        queue += more
        if thenAdvance, index + 1 < queue.count {
            index += 1
            load(rise: false)
        }
    }

    // MARK: Now Playing on the system

    private func updateNowPlaying() {
        guard let song = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        guard let art = song.artwork else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: art), let image = UIImage(data: data),
                  current?.id == song.id else { return }
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
