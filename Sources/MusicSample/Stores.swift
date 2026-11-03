import AppKit
import SwiftUI


enum RepeatMode: String { case off, all, one }

enum Prefs {
    private static let d = UserDefaults.standard
    static func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
    static func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
    static func bool(_ key: String, _ fallback: Bool = false) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
    static func string(_ key: String) -> String? { d.string(forKey: key) }
    static func strings(_ key: String) -> [String] { d.stringArray(forKey: key) ?? [] }
    static func set(_ value: Any, _ key: String) { d.set(value, forKey: key) }
}

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat", bass = "Bass boost", vocal = "Vocal", treble = "Treble boost", night = "Late night"
    var id: String { rawValue }
}

enum SleepTimer: String, CaseIterable, Identifiable {
    case off = "Off", m15 = "15 minutes", m30 = "30 minutes", h1 = "1 hour", endOfSong = "End of song"
    var id: String { rawValue }
}

/// Playback through mpv, with stream URLs from yt-dlp.
@Observable final class Player {
    var queue: [Song] = []
    var index = 0
    var isPlaying = false
    var isLoading = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var lastError: String?
    // Player settings are kept between launches.
    var volume = Prefs.double("volume", 0.7) {
        didSet { applyVolume(); Prefs.set(volume, "volume") }
    }
    var shuffle = Prefs.bool("shuffle") { didSet { Prefs.set(shuffle, "shuffle") } }
    var isMuted = false { didSet { engines.forEach { $0.set("mute", isMuted ? "yes" : "no") } } }
    var repeatMode = RepeatMode(rawValue: Prefs.string("repeat") ?? "") ?? .off {
        didSet { Prefs.set(repeatMode.rawValue, "repeat") }
    }
    /// Seconds the end of one song overlaps the start of the next (0 = off).
    var crossfade = Prefs.double("crossfade", 0) { didSet { Prefs.set(crossfade, "crossfade") } }
    /// At the end of the queue, keep going with YouTube Music's radio for the last song.
    var autoplay = Prefs.bool("autoplay", true) { didSet { Prefs.set(autoplay, "autoplay") } }
    /// Fetches the radio; set by the app, which owns the YouTube client.
    @ObservationIgnored var radio: ((Song) async -> [Song])?
    /// The library's latest copy of a song, for queue entries saved before YouTube's
    /// track type was known.
    @ObservationIgnored var latest: ((String) -> Song?)?
    /// Counts a play in your YouTube history (see `YTClient.addToHistory`).
    @ObservationIgnored var reportPlay: ((Song) async -> Void)?
    @ObservationIgnored private var reportedPlay: String?
    var addToHistory = Prefs.bool("addToHistory", true) { didSet { Prefs.set(addToHistory, "addToHistory") } }
    var gapless = true
    var eq = EQPreset.flat
    /// Turn loud tracks down the way YouTube Music does (on by default).
    var matchLoudness = Prefs.bool("matchLoudness", true) {
        didSet {
            Prefs.set(matchLoudness, "matchLoudness")
            engine.set("volume-gain", String(format: "%.2f", matchLoudness ? currentGain : 0))
        }
    }
    var sleepTimer = SleepTimer.off
    var skipForward = true
    /// Song or music video for the current track (Pear's video-toggle). Switching
    /// reloads the track as the other kind, from the same moment.
    var videoMode = false {
        didSet {
            guard oldValue != videoMode, !settingVideoForNewQueue else { return }
            // Your own switch is remembered: new songs start the way you last chose.
            prefersVideo = videoMode
            guard !needsLoad, let song = current else { return }
            // A song and its video share one timeline, so the audio keeps playing and
            // only the picture is added or hidden. Reloading the track cut the sound out.
            guard !isLoading, lastError == nil else {
                return load(at: position, autoplay: isPlaying, followLive: true)
            }
            if videoMode { attachVideo(to: song) } else { engine.hideVideo() }
        }
    }
    /// Songs start as music videos only after you last switched to video yourself.
    @ObservationIgnored private(set) var prefersVideo = Prefs.bool("prefersVideo") {
        didSet { Prefs.set(prefersVideo, "prefersVideo") }
    }
    /// The picture is on its way for a song that's already playing.
    var videoLoading = false
    /// Width / height of the video picture; an album track's "video" is often its
    /// square cover.
    var videoAspect = 16.0 / 9

    /// Highest video resolution to ask for (Pear's quality-changer).
    var videoQuality = Prefs.int("videoQuality", 1080) {
        didSet {
            Prefs.set(videoQuality, "videoQuality")
            guard oldValue != videoQuality, videoMode, let song = current else { return }
            if isLoading { load(at: position, autoplay: isPlaying, followLive: true) } else { attachVideo(to: song) }
        }
    }

    /// The current song as your Discord status.
    var discordPresence = Prefs.bool("discordPresence", true) {
        didSet {
            Prefs.set(discordPresence, "discordPresence")
            if discordPresence { publishNowPlaying() } else { discord.clear() }
        }
    }
    @ObservationIgnored private let discord = DiscordPresence()

    /// Fade the volume on pause, resume and skips instead of cutting (your smooth-transitions plugin).
    var smoothTransitions = Prefs.bool("smoothTransitions", true) {
        didSet { Prefs.set(smoothTransitions, "smoothTransitions") }
    }

    /// Two mpv instances only while crossfading: the next song starts on the other one
    /// and that one carries on. The second is made the first time it's needed.
    @ObservationIgnored private var engines = [MpvEngine()]
    private var active = 0
    var engine: MpvEngine { engines[active] }
    /// The engine still playing the end of the previous song during a crossfade.
    @ObservationIgnored private var outgoing: MpvEngine?
    @ObservationIgnored private var outgoingTimer: Timer?
    @ObservationIgnored private var crossfading = false
    /// A song restored from last time; nothing is loaded in mpv until Play.
    @ObservationIgnored private var needsLoad = false
    @ObservationIgnored private var radioSeed: String?
    @ObservationIgnored private var fadeLevel = 1.0
    @ObservationIgnored private var fadeTimer: Timer?
    /// The track ended by itself; the next one starts at full volume, no fade-in.
    @ObservationIgnored private var advancingNaturally = false
    /// The new track fades in once mpv reports it actually playing: mpv may set up a
    /// fresh audio output for it, which would start at full volume and skip the fade.
    @ObservationIgnored private var fadeInWhenPlaying = false
    /// Between loadfile and mpv's "file loaded", position and length reports still
    /// belong to the previous track; they're ignored so the bar doesn't jump.
    @ObservationIgnored private var awaitingFile = false
    /// mpv's real position, kept up to date even while another load is resolving.
    @ObservationIgnored private var livePosition: TimeInterval = 0
    @ObservationIgnored private let resolver = StreamResolver()
    @ObservationIgnored private var nowPlaying: NowPlayingCenter?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var settingVideoForNewQueue = false
    @ObservationIgnored private var currentGain = 0.0

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Song] { queue.indices.contains(index) ? Array(queue[(index + 1)...]) : [] }
    /// mpv's duration once known; Home items arrive without one.
    var length: TimeInterval { duration > 0 ? duration : (current?.duration ?? 0) }

    init() {
        wire(engines[0])
        applyVolume()
        restoreSession()
        nowPlaying = NowPlayingCenter(player: self)
        publishNowPlaying()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveSession(now: true)
        }
    }

    /// Only the active engine speaks for the player; the outgoing one during a
    /// crossfade is ignored, its end included.
    private func wire(_ e: MpvEngine) {
        e.onFileLoaded = { [weak self, unowned e] in
            guard let self, e === self.engine else { return }
            self.awaitingFile = false
        }
        e.onVideoAspect = { [weak self, unowned e] aspect in
            // Ignore tiny changes so the stage never jitters.
            guard let self, e === self.engine, aspect > 0.2, abs(aspect - self.videoAspect) > 0.03 else { return }
            self.videoAspect = aspect
        }
        e.onTime = { [weak self, unowned e] t in
            guard let self, e === self.engine, !self.awaitingFile else { return }
            self.livePosition = t
            guard !self.isLoading else { return }
            self.position = t
            if self.fadeInWhenPlaying {
                self.fadeInWhenPlaying = false
                self.fadeLevel = 0
                self.applyFade()
                self.fade(to: 1, over: self.crossfading ? self.crossfade : 0.4, always: self.crossfading)
                self.crossfading = false
            }
            self.startCrossfadeIfDue(at: t)
            // Ten seconds in, like YouTube Music's own player, so skipped songs don't count.
            if t > 10, self.addToHistory, !Demo.isOn, let song = self.current, self.reportedPlay != song.id {
                self.reportedPlay = song.id
                Task { await self.reportPlay?(song) }
            }
        }
        e.onDuration = { [weak self, unowned e] d in
            guard let self, e === self.engine, !self.awaitingFile else { return }
            self.duration = d
            self.publishNowPlaying()
        }
        e.onPause = { [weak self, unowned e] paused in
            // mpv reports "not paused" while idle; a restored song isn't loaded yet.
            guard let self, e === self.engine, !self.isLoading, !self.needsLoad, self.current != nil else { return }
            self.isPlaying = !paused
            self.publishNowPlaying()
        }
        e.onEnded = { [weak self, unowned e] in
            guard let self, e === self.engine else { return }
            self.trackEnded()
        }
        e.onError = { [weak self, unowned e] message in
            guard let self, e === self.engine else { return }
            self.lastError = "Playback failed: \(message)"
            self.isPlaying = false
        }
    }

    // MARK: Crossfade

    /// Near the end of a song, starts the next one on the other engine and lets
    /// this one fade out underneath it. Not for videos, repeat-one, or short songs.
    private func startCrossfadeIfDue(at t: TimeInterval) {
        guard crossfade > 0, outgoing == nil, isPlaying, !videoMode, repeatMode != .one,
              length > crossfade * 2 + 5, t >= length - crossfade,
              index + 1 < queue.count || repeatMode == .all else { return }
        let old = engine
        if engines.count == 1 {
            let second = MpvEngine()
            wire(second)
            engines.append(second)
        }
        active = 1 - active
        engine.set("mute", isMuted ? "yes" : "no")
        outgoing = old
        let from = fadeLevel
        let began = Date()
        let seconds = crossfade
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            let progress = min(1, Date().timeIntervalSince(began) / seconds)
            _ = old.trySet("ao-volume", String(format: "%.1f", from * (1 - progress) * 100))
            if progress >= 1 { timer.invalidate(); self?.finishCrossfade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        outgoingTimer = timer
        crossfading = true
        fadeLevel = 0
        skipForward = true
        index = index + 1 < queue.count ? index + 1 : 0
        load()
    }

    /// Stops the outgoing song: at the end of the fade, or at once when you skip,
    /// pause or pick something else mid-crossfade.
    private func finishCrossfade() {
        outgoingTimer?.invalidate()
        outgoingTimer = nil
        outgoing?.stop()
        outgoing = nil
    }

    // MARK: Session

    private struct Session: Codable {
        let queue: [Song]
        let index: Int
    }

    /// The queue and song, so the next launch picks up here (paused, from the start).
    private func saveSession(now: Bool = false) {
        guard current != nil, !Demo.isOn else { return }
        // A long queue is cut to the part around the current song.
        let start = max(0, index - 50)
        let end = min(queue.count, index + 500)
        DiskCache.save(Session(queue: Array(queue[start..<end]), index: index - start), "session", now: now)
    }

    private func restoreSession() {
        if Demo.isOn {
            queue = Demo.songs
            position = 72
            duration = queue[0].duration
            needsLoad = true
            return
        }
        guard let s = DiskCache.load(Session.self, "session"), s.queue.indices.contains(s.index) else { return }
        queue = s.queue
        index = s.index
        // Comes back as the song, not the video: an unloaded video showed as a black box.
        duration = s.queue[s.index].duration
        needsLoad = true
    }

    /// Resolves the song restored from last time (and the one after it) once you're
    /// signed in, so Play starts it at once, the way you last chose.
    func prepareRestored() async {
        guard needsLoad, let song = current else { return }
        await resolver.prepare([song.id] + upNext.prefix(1).map(\.id), video: prefersVideo, maxHeight: videoQuality)
    }

    // MARK: Autoplay

    /// On the last song or the one before it, adds YouTube's radio for it to the queue.
    private func extendWithRadioIfNeeded() {
        guard autoplay, repeatMode == .off, index >= queue.count - 2, let seed = current else { return }
        appendRadio(after: seed)
    }

    /// Plays a song followed by its radio, as YouTube Music does for songs on Home.
    /// The song already playing keeps playing; only what comes after it changes.
    func playRadio(_ song: Song) {
        if song.id == current?.id, !needsLoad {
            queue = [song]
            index = 0
        } else {
            play(song, in: [song])
        }
        radioSeed = nil
        appendRadio(after: song)
    }

    private func appendRadio(after seed: Song) {
        guard radioSeed != seed.id, let radio else { return }
        radioSeed = seed.id
        Task { @MainActor [weak self] in
            let songs = await radio(seed)
            guard let self, self.current?.id == seed.id else { return }
            let have = Set(self.queue.map(\.id))
            self.queue += songs.filter { !have.contains($0.id) }
            // The radio usually arrives after the song's own load queued nothing next.
            await self.resolver.prepare(self.upNext.prefix(2).map(\.id), video: self.videoMode, maxHeight: self.videoQuality)
        }
    }

    /// Resolves the current track's streams (cached or prefetched when possible)
    /// and hands them to mpv. A newer load cancels an older one still resolving.
    /// `followLive`: the same track as another kind (song to video, a new quality).
    /// It keeps playing while the new streams load, so the switch picks up from
    /// wherever it has got to by then instead of jumping back.
    private func load(at start: TimeInterval = 0, autoplay: Bool = true, followLive: Bool = false) {
        guard let song = current else {
            engine.stop()
            return
        }
        loadToken += 1
        let token = loadToken
        reportedPlay = nil
        // A new track plays the way you last chose, except that a song with no music
        // video (only its cover) plays as audio; the next one with a video goes back.
        if !followLive {
            settingVideoForNewQueue = true
            videoMode = prefersVideo && (song.videoType == nil ? latest?(song.id) ?? song : song).hasVideo
            settingVideoForNewQueue = false
        }
        needsLoad = false
        let fadeIn = crossfading || (smoothTransitions && !advancingNaturally)
        advancingNaturally = false
        isLoading = true
        isPlaying = autoplay
        position = start
        duration = song.duration
        lastError = nil
        publishNowPlaying()
        let video = videoMode
        let height = videoQuality
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let streams = try await self.resolver.resolve(song.id, video: video, maxHeight: height)
                let wait = streams.availableAt.timeIntervalSinceNow + 0.2
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                guard token == self.loadToken else { return }
                // The previous track kept playing while this one resolved; fade it out
                // only now that the new one is ready.
                if self.smoothTransitions, self.fadeLevel > 0.05 {
                    self.fade(to: 0, over: 0.2)
                    try await Task.sleep(for: .milliseconds(220))
                    guard token == self.loadToken else { return }
                }
                self.currentGain = streams.gainDb
                self.fadeTimer?.invalidate()
                self.fadeLevel = fadeIn ? 0 : 1
                if fadeIn {
                    // Silent on both levels until mpv reports the new track playing.
                    _ = self.engine.trySet("ao-volume", "0")
                    self.engine.set("volume", "0")
                } else {
                    self.applyVolume()
                }
                self.fadeInWhenPlaying = fadeIn
                self.awaitingFile = true
                let begin = followLive ? self.livePosition + 0.2 : start
                self.position = begin
                self.engine.load(audio: streams.audio, video: streams.video, start: begin, paused: !autoplay,
                                 gainDb: self.matchLoudness ? streams.gainDb : 0)
                self.isLoading = false
                self.saveSession()
                self.extendWithRadioIfNeeded()
                // The next two are songs you're about to hear, so they don't wait in line
                // behind songs you hovered; the third goes in the background line.
                await self.resolver.prepare(self.upNext.prefix(2).map(\.id), video: video, maxHeight: height)
                await self.resolver.prefetch(self.upNext.dropFirst(2).prefix(1).map(\.id), video: video, maxHeight: height)
            } catch {
                guard token == self.loadToken else { return }
                self.crossfading = false
                self.fade(to: 0, over: 0.2) { [weak self] in self?.engine.set("pause", "yes") }
                self.isLoading = false
                self.isPlaying = false
                let message = error.localizedDescription
                // YouTube's answer when it decides there were too many requests from here.
                self.lastError = message.contains("not a bot")
                    ? "YouTube is asking to confirm you're not a bot. Try again in a while."
                    : message
            }
        }
    }

    private func attachVideo(to song: Song) {
        let token = loadToken
        let height = videoQuality
        videoLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.loadToken { self.videoLoading = false } }
            do {
                let streams = try await self.resolver.resolve(song.id, video: true, maxHeight: height)
                let wait = streams.availableAt.timeIntervalSinceNow + 0.2
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                guard token == self.loadToken, self.videoMode, self.current?.id == song.id,
                      let video = streams.video else { return }
                self.engine.addVideo(video)
            } catch {
                guard token == self.loadToken else { return }
                self.lastError = error.localizedDescription.contains("not a bot")
                    ? "YouTube is asking to confirm you're not a bot. Try again in a while."
                    : error.localizedDescription
            }
        }
    }

    /// Starts resolving a song the pointer rests on, so a click on it starts sooner.
    /// `video` nil: the kind this song would start as (your last choice, audio for a
    /// song with no video), so the hover prepares what a click will actually play.
    func prefetch(_ song: Song, video: Bool? = nil) {
        let height = videoQuality
        let video = video ?? (prefersVideo && song.hasVideo)
        Task { await resolver.prefetch([song.id], video: video, maxHeight: height) }
    }

    func play(_ song: Song, in list: [Song], at start: TimeInterval = 0) {
        var list = list.isEmpty ? [song] : list
        var first = list.firstIndex(of: song) ?? 0
        if shuffle {
            list = [song] + list.enumerated().filter { $0.offset != first }.map(\.element).shuffled()
            first = 0
        }
        finishCrossfade()
        crossfading = false
        settingVideoForNewQueue = true
        videoMode = prefersVideo
        settingVideoForNewQueue = false
        skipForward = true
        queue = list
        index = first
        load(at: start)
    }

    func playAll(_ songs: [Song], shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        let list = shuffled ? songs.shuffled() : songs
        play(list[0], in: list)
    }

    func jump(to queueIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        finishCrossfade()
        crossfading = false
        skipForward = queueIndex > index
        index = queueIndex
        load()
    }

    func toggle() {
        guard current != nil else { return }
        if needsLoad {
            settingVideoForNewQueue = true
            videoMode = prefersVideo
            settingVideoForNewQueue = false
        }
        if lastError != nil || needsLoad { return load(at: position) }
        finishCrossfade()
        isPlaying.toggle()
        if isPlaying {
            if smoothTransitions {
                fadeLevel = 0
                applyVolume()
            }
            engine.set("pause", "no")
            fade(to: 1, over: 0.2)
        } else {
            fade(to: 0, over: 0.15) { [weak self] in
                guard let self, !self.isPlaying else { return }
                self.engine.set("pause", "yes")
            }
            saveSession()
        }
        publishNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if !advancingNaturally { finishCrossfade(); crossfading = false }
        skipForward = true
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            engine.stop()
            isPlaying = false
            position = 0
            publishNowPlaying()
            return
        }
        load()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        finishCrossfade()
        crossfading = false
        if position > 3 || index == 0 {
            // Rewind to the start: fade out, jump, fade back in.
            fade(to: 0, over: 0.15) { [weak self] in
                self?.seek(0)
                self?.fade(to: 1, over: 0.3)
            }
        } else {
            skipForward = false
            index -= 1
            load()
        }
    }

    private func trackEnded() {
        advancingNaturally = true
        if repeatMode == .one { load() } else { next() }
    }

    /// Ramps the volume between silent (0) and the slider's level (1), then runs `done`.
    /// `always`: fade even with smooth transitions off (a crossfade).
    private func fade(to target: Double, over seconds: Double, always: Bool = false, then done: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard smoothTransitions || always, seconds > 0 else {
            fadeLevel = target
            applyVolume()
            done?()
            return
        }
        let from = fadeLevel
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let progress = min(1, Date().timeIntervalSince(began) / seconds)
            self.fadeLevel = from + (target - from) * progress
            self.applyVolume()
            if progress >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
                done?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    func seek(_ time: TimeInterval) {
        finishCrossfade()
        position = time
        engine.seek(time)
        publishNowPlaying()
    }

    func toggleMute() { isMuted.toggle() }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func playNext(_ songs: [Song]) {
        guard current != nil else { return playAll(songs) }
        queue.insert(contentsOf: songs, at: index + 1)
    }

    func addToQueue(_ songs: [Song]) {
        guard current != nil else { return playAll(songs) }
        queue.append(contentsOf: songs)
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        var up = upNext
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + up
    }

    func removeUpNext(at offsets: IndexSet) {
        var up = upNext
        up.remove(atOffsets: offsets)
        queue = Array(queue[...index]) + up
    }

    /// Empties Up Next; the current song keeps playing.
    func clearUpNext() {
        guard queue.indices.contains(index) else { return }
        queue = [queue[index]]
        radioSeed = current?.id
    }

    /// Squared, so the slider's lower half isn't all "loud" (Pear's exponential-volume).
    private func applyVolume() { applyFade() }

    /// Fades act on mpv's output volume (`ao-volume`), which the sound device applies
    /// straight away. mpv's normal volume works before its ~0.2 s audio buffer, so a
    /// short fade there finished before anyone heard it and the pause then cut in.
    /// The slider stays on the normal volume. Without an audio output yet, the fade
    /// falls back to the normal volume.
    private func applyFade() {
        let level = volume * volume * 100
        let aoOK = engine.trySet("ao-volume", String(format: "%.1f", fadeLevel * 100))
        if aoOK {
            engine.set("volume", String(format: "%.1f", level))
        } else {
            engine.set("volume", String(format: "%.1f", level * fadeLevel))
        }
    }

    private func publishNowPlaying() {
        nowPlaying?.update(song: current, position: position, duration: length, playing: isPlaying)
        // A restored song that hasn't been played yet isn't something you're listening to.
        if discordPresence, !needsLoad, !Demo.isOn {
            discord.update(song: current, position: position, duration: length, playing: isPlaying)
        }
    }
}

/// Home section order and visibility, by section title, kept between launches.
@Observable final class HomeConfig {
    var order: [String] = UserDefaults.standard.stringArray(forKey: "homeOrder") ?? [] {
        didSet { UserDefaults.standard.set(order, forKey: "homeOrder") }
    }
    var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "homeHidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "homeHidden") }
    }

    /// Sections the user hasn't placed yet keep YouTube's order, after the placed ones.
    func arrange(_ shelves: [HomeShelf]) -> [HomeShelf] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return shelves.enumerated()
            .filter { !hidden.contains($0.element.title) }
            .sorted { (rank[$0.element.title] ?? Int.max, $0.offset) < (rank[$1.element.title] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    func learn(_ shelves: [HomeShelf]) {
        let new = shelves.map(\.title).filter { !order.contains($0) }
        if !new.isEmpty { order += new }
    }

    func reset() {
        order = []
        hidden = []
    }
}

/// A one-line question, such as a new playlist's name, asked over the window.
struct TextPrompt {
    let title: String
    let button: String
    var text = ""
    let done: (String) -> Void
}

@Observable final class Router {
    var current = Route.home
    var prompt: TextPrompt?
    var backStack: [Route] = []
    var forwardStack: [Route] = []
    var showNowPlaying = false
    var panelVisible = false
    var panelTab = PanelTab.queue

    var videoFullscreen = false
    var showShortcuts = false
    /// Bumped by / and ⌘K so the search field takes focus even when Search is already open.
    var searchFocusRequest = 0
    var showPalette = false
    /// The floating video in the corner was closed for the current video session.
    var miniPlayerHidden = false

    @ObservationIgnored var pointerOverShelf = false
    @ObservationIgnored var pointerOverPlayerSong = false
    @ObservationIgnored private var windowWasFullscreen = false

    /// Video covers the whole window, and the window goes into its own fullscreen Space.
    func enterVideoFullscreen() {
        guard !videoFullscreen else { return }
        videoFullscreen = true
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        windowWasFullscreen = window.styleMask.contains(.fullScreen)
        if !windowWasFullscreen { window.toggleFullScreen(nil) }
    }

    func exitVideoFullscreen() {
        guard videoFullscreen else { return }
        videoFullscreen = false
        NSCursor.unhide()
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        if !windowWasFullscreen, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func go(_ route: Route) {
        showNowPlaying = false
        guard route != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = route
    }

    /// Asks for a name, then makes the playlist with `songs` in it.
    func newPlaylist(_ library: Library, with songs: [Song] = [], name: String = "") {
        prompt = TextPrompt(title: "New Playlist", button: "Create", text: name) { title in
            Task { await library.createPlaylist(title, with: songs) }
        }
    }

    func openSearch() {
        go(.search)
        searchFocusRequest += 1
    }

    func goBack() {
        if showNowPlaying { showNowPlaying = false; return }
        guard let r = backStack.popLast() else { return }
        forwardStack.append(current)
        current = r
    }

    func goForward() {
        guard let r = forwardStack.popLast() else { return }
        backStack.append(current)
        current = r
    }

    func togglePanel(_ tab: PanelTab) {
        if panelVisible && panelTab == tab {
            panelVisible = false
        } else {
            panelTab = tab
            panelVisible = true
        }
    }
}

/// Two-finger horizontal swipes: over the player's song they skip tracks,
/// elsewhere they go back/forward like Safari. Shelves keep their own scrolling.
final class SwipeTracker {
    private var accumulated: CGFloat = 0
    private var vertical: CGFloat = 0
    private var tracking = false
    private var fired = false
    private var installed = false

    /// Uses the event tap: with responsive scrolling a local monitor misses most trackpad events.
    @MainActor func install(router: Router, player: Player) {
        guard !installed else { return }
        installed = true
        ScrollEventTap.shared.subscribe { [weak self] event in
            self?.handle(event, router: router, player: player)
        }
    }

    private func handle(_ e: NSEvent, router: Router, player: Player) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        if e.phase == .began {
            accumulated = 0
            vertical = 0
            fired = false
            tracking = true
        }
        guard tracking else { return }
        if e.phase == .changed {
            accumulated += e.scrollingDeltaX
            vertical += abs(e.scrollingDeltaY)
            if !fired, abs(accumulated) > 70, abs(accumulated) > vertical * 2 {
                fired = true
                let fingersRight = e.isDirectionInvertedFromDevice ? accumulated > 0 : accumulated < 0
                withAnimation(.snappy) {
                    if router.pointerOverPlayerSong {
                        fingersRight ? player.previous() : player.next()
                    } else if !router.pointerOverShelf {
                        fingersRight ? router.goBack() : router.goForward()
                    }
                }
            }
        }
        if e.phase == .ended || e.phase == .cancelled { tracking = false }
    }
}

/// Plays a table row on a plain single click, but not when the click turns into a drag.
enum ClickToPlay {
    private static var token = 0

    static func arm(_ action: @escaping () -> Void) {
        if let e = NSApp.currentEvent, e.type == .keyDown { return }
        token += 1
        let mine = token
        let start = NSEvent.mouseLocation
        func check() {
            guard mine == token else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                let end = NSEvent.mouseLocation
                if hypot(end.x - start.x, end.y - start.y) < 6 { action() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: check)
            }
        }
        check()
    }
}

/// Single-key shortcuts, like anicat's: they work anywhere except while typing
/// in a text field. Up/down stay with a focused list or table.
enum KeyboardShortcuts {
    private static var monitor: Any?

    static func install(player: Player, router: Router) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event, player: player, router: router) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, player: Player, router: Router) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let responder = event.window?.firstResponder
        // Option-arrows go back and forward, like a browser.
        if mods == .option, event.keyCode == 123 { router.goBack(); return true }
        if mods == .option, event.keyCode == 124 { router.goForward(); return true }
        guard mods.isEmpty || mods == .shift, !(responder is NSText), event.window?.sheetParent == nil else { return false }
        let inList = responder is NSTableView
        switch event.keyCode {
        case 49: player.toggle(); return true                                   // space
        case 123: player.seek(max(0, player.position - 5)); return true         // left
        case 124: player.seek(min(player.length, player.position + 5)); return true // right
        case 126 where !inList: player.volume = min(1, player.volume + 0.05); return true // up
        case 125 where !inList: player.volume = max(0, player.volume - 0.05); return true // down
        default: break
        }
        switch event.charactersIgnoringModifiers ?? "" {
        case "?": withAnimation(.snappy) { router.showShortcuts.toggle() }
        case "m": player.toggleMute()
        case "s": player.shuffle.toggle()
        case "r": player.cycleRepeat()
        case "v": if player.current != nil { player.videoMode.toggle() }
        case "f": if player.videoMode { router.videoFullscreen ? router.exitVideoFullscreen() : router.enterVideoFullscreen() }
        case "n": if player.current != nil { withAnimation(.spring(duration: 0.45, bounce: 0)) { router.showNowPlaying.toggle() } }
        case "l": router.togglePanel(.lyrics)
        case "q": router.togglePanel(.queue)
        case "/": router.openSearch()
        default: return false
        }
        return true
    }

    static let list: [(String, String)] = [
        ("Space", "Play / pause"), ("← →", "Back / forward 5 seconds"), ("↑ ↓", "Volume"),
        ("⌘← ⌘→", "Previous / next song"), ("M", "Mute"), ("S", "Shuffle"), ("R", "Repeat"),
        ("V", "Song / music video"), ("F", "Fullscreen video"), ("N", "Now Playing"),
        ("L", "Lyrics"), ("Q", "Up Next"), ("⌘L", "Like"),
        ("⌘1 – ⌘9", "Home, Search, Liked, Albums, playlists"), ("/", "Search"), ("⌘K", "Command palette"),
        ("⌘[ ⌘]  or  ⌥← ⌥→", "Back / forward"), ("⌘,", "Settings"), ("?", "This list"),
    ]
}
