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
    /// ffmpeg filters for mpv, turned down where they boost so loud songs don't clip.
    var filter: String {
        switch self {
        case .flat: ""
        case .bass: "equalizer=f=60:t=o:w=2:g=6,equalizer=f=150:t=o:w=1.5:g=3,volume=0.6"
        case .vocal: "equalizer=f=120:t=o:w=1.5:g=-3,equalizer=f=2500:t=o:w=1.5:g=4,volume=0.75"
        case .treble: "equalizer=f=3000:t=o:w=1.5:g=2,equalizer=f=9000:t=o:w=2:g=6,volume=0.6"
        // Quiet parts up, loud parts down.
        case .night: "acompressor=threshold=0.1:ratio=4:attack=20:release=250:makeup=2"
        }
    }
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
    /// Where a swipe over the player bar is seeking to, shown until the fingers lift.
    var scrubPosition: TimeInterval?
    var duration: TimeInterval = 0
    var lastError: String?
    // Player settings are kept between launches.
    var volume = Prefs.double("volume", 0.7) {
        didSet { applyVolume(); Prefs.set(volume, "volume") }
    }
    /// Turning it on mixes up Up Next; turning it off puts it back in its own order.
    var shuffle = Prefs.bool("shuffle") {
        didSet {
            Prefs.set(shuffle, "shuffle")
            guard shuffle != oldValue, !settingShuffle, queue.indices.contains(index) else { return }
            let played = Array(queue[...index])
            if shuffle {
                unshuffledUpNext = upNext
                queue = played + upNext.shuffled()
            } else if let original = unshuffledUpNext {
                // The original order of what's still to come, then anything queued since.
                let left = Set(upNext.map(\.id)), known = Set(original.map(\.id))
                queue = played + original.filter { left.contains($0.id) } + upNext.filter { !known.contains($0.id) }
                unshuffledUpNext = nil
            }
        }
    }
    @ObservationIgnored private var unshuffledUpNext: [Song]?
    @ObservationIgnored private var settingShuffle = false
    var isMuted = false { didSet { engines.forEach { $0.set("mute", isMuted ? "yes" : "no") } } }
    var repeatMode = RepeatMode(rawValue: Prefs.string("repeat") ?? "") ?? .off {
        didSet { Prefs.set(repeatMode.rawValue, "repeat") }
    }
    /// Seconds the end of one song overlaps the start of the next (0 = off).
    var crossfade = Prefs.double("crossfade", 0) { didSet { Prefs.set(crossfade, "crossfade"); replan() } }
    /// Crossfades planned from the music: quiet ends skipped, songs meeting on a beat.
    var smartTransitions = Prefs.bool("smartTransitions", false) {
        didSet {
            Prefs.set(smartTransitions, "smartTransitions")
            replan()
        }
    }
    /// At the end of the queue, keep going with YouTube Music's radio for the last song.
    var autoplay = Prefs.bool("autoplay", true) { didSet { Prefs.set(autoplay, "autoplay") } }
    /// Fetches the radio; set by the app, which owns the YouTube client.
    @ObservationIgnored var radio: ((Song) async -> [Song])?
    /// What you asked the mood box for; while set, Up Next keeps filling from it
    /// instead of the radio, whatever the Autoplay setting.
    private(set) var mood: String?
    /// The request being searched for, shown until its songs arrive.
    private(set) var moodLoading: String?
    /// Finds songs for a mood; set by the app, which owns the YouTube client.
    @ObservationIgnored var moodSongs: ((String) async -> [Song])?
    @ObservationIgnored private var moodPool: [Song] = []
    /// Bumped by every new or ended mood, so a slow search for an old one is dropped.
    @ObservationIgnored private var moodGeneration = 0
    /// The library's latest copy of a song, for queue entries saved before YouTube's
    /// track type was known.
    @ObservationIgnored var latest: ((String) -> Song?)?
    /// Counts a play in your YouTube history (see `YTClient.addToHistory`).
    @ObservationIgnored var reportPlay: ((Song) async -> Void)?
    @ObservationIgnored private var reportedPlay: String?
    var addToHistory = Prefs.bool("addToHistory", true) { didSet { Prefs.set(addToHistory, "addToHistory") } }
    /// With no crossfade, the next song is loaded ahead and starts the moment this one ends.
    var gapless = Prefs.bool("gapless", true) { didSet { Prefs.set(gapless, "gapless"); replan() } }
    var eq = EQPreset(rawValue: Prefs.string("eq") ?? "") ?? .flat {
        didSet {
            Prefs.set(eq.rawValue, "eq")
            engines.forEach { $0.preset = eq.filter }
        }
    }
    /// Turn loud tracks down the way YouTube Music does (on by default).
    var matchLoudness = Prefs.bool("matchLoudness", true) {
        didSet {
            Prefs.set(matchLoudness, "matchLoudness")
            engine.set("volume-gain", String(format: "%.2f", matchLoudness ? currentGain : 0))
        }
    }
    var sleepTimer = SleepTimer.off {
        didSet {
            sleepWork?.cancel()
            let minutes = [SleepTimer.m15: 15.0, .m30: 30, .h1: 60][sleepTimer]
            guard let minutes else { return replan() }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.sleepTimer = .off
                if self.isPlaying { self.toggle() }
            }
            sleepWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60, execute: work)
        }
    }
    @ObservationIgnored private var sleepWork: DispatchWorkItem?
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
    @ObservationIgnored private lazy var engines: [MpvEngine] = {
        let e = MpvEngine()
        e.preset = eq.filter
        return [e]
    }()
    private var active = 0
    var engine: MpvEngine { engines[active] }
    /// A smart transition under way: the song being mixed out, when the mix began
    /// and how long it lasts, for the player bar's cover blend.
    private(set) var mix: Mix?
    struct Mix {
        let from: Song
        let began: Date
        let seconds: TimeInterval
        /// Rises and falls over the mix, for glows that fade in and out on their own.
        func swell(at date: Date) -> Double {
            sin(.pi * min(1, max(0, date.timeIntervalSince(began) / seconds)))
        }
    }
    /// Shorter overlaps are just a crossfade, not shown as a mix.
    static let minimumMix: TimeInterval = 6
    /// Where in the playing song the next one will mix in, once planned.
    var upcomingMix: TimeInterval? {
        guard mix == nil, smartTransitions, sleepTimer != .endOfSong, !videoMode, let t = transition, t.key == transitionKey,
              t.plan.fade >= Self.minimumMix else { return nil }
        return t.plan.outAt
    }
    /// The engine still playing the end of the previous song during a crossfade.
    @ObservationIgnored private var outgoing: MpvEngine?
    @ObservationIgnored private var outgoingTimer: Timer?
    @ObservationIgnored private var crossfading = false
    /// Length of the crossfade under way (planned, or the Crossfade setting).
    @ObservationIgnored private var fadeSeconds = 0.0
    /// The outgoing song's level when its crossfade began.
    @ObservationIgnored private var outgoingLevel = 1.0
    /// The plan for going from the playing song into the next ("a>b").
    @ObservationIgnored private var transition: (key: String, plan: TransitionPlan)?
    @ObservationIgnored private var planningKey: String?
    /// The next song loaded paused on the other engine, waiting for its beat.
    @ObservationIgnored private var prepared: (key: String, engine: MpvEngine, gain: Double, ready: Bool)?
    @ObservationIgnored private var preparedStart: DispatchWorkItem?
    /// A beat-matched mix's bass swap and speed ease, stopped if the mix is cut short.
    @ObservationIgnored private var mixTimers: [Timer] = []
    /// How long a paused engine takes to be heard after unpausing (s), learned from
    /// each mix and taken off the start time so the beats land together.
    @ObservationIgnored private var startLead = Prefs.double("mixStartLead", 0.05)
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
    /// A seek asked for while the song was still loading (mpv ignores it then);
    /// applied once the file is loaded.
    @ObservationIgnored private var pendingSeek: TimeInterval?
    /// mpv's real position, kept up to date even while another load is resolving.
    @ObservationIgnored private var livePosition: TimeInterval = 0 {
        didSet {
            // mpv reports in uneven bursts, so the bar runs on its own steady clock and
            // only resets it when a report disagrees, or after a pause or a stall.
            let now = Date()
            if now.timeIntervalSince(liveStamp) > 1 || abs(livePosition - clock.position - now.timeIntervalSince(clock.at)) > 0.3 {
                clock = (livePosition, now)
            }
            liveStamp = now
        }
    }
    @ObservationIgnored private var liveStamp = Date()
    @ObservationIgnored private var clock = (position: TimeInterval(0), at: Date())
    /// Where playback is at `date`, gliding between mpv's reports.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying, abs(livePosition - position) < 1, date.timeIntervalSince(liveStamp) < 1 else { return position }
        return clock.position + max(0, date.timeIntervalSince(clock.at))
    }
    @ObservationIgnored private let resolver = StreamResolver()
    @ObservationIgnored private var nowPlaying: NowPlayingCenter?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var settingVideoForNewQueue = false
    @ObservationIgnored private var currentGain = 0.0

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Song] { queue.indices.contains(index) ? Array(queue[(index + 1)...]) : [] }
    /// What played before the current song, oldest first.
    var played: [Song] { Array(queue.prefix(min(index, queue.count))) }
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
            guard let self else { return }
            if let p = self.prepared, p.engine === e {
                self.prepared?.ready = true
                // It comes in thin (no lows, soft highs) and opens up during the mix when beat-matched.
                if self.transition?.plan.matched == true {
                    e.setBass(-24)
                    e.setHighs(-12)
                } else {
                    e.setBass(0)
                    e.setHighs(0)
                }
                return
            }
            guard e === self.engine else { return }
            self.awaitingFile = false
            if let t = self.pendingSeek {
                self.pendingSeek = nil
                e.seek(t)
            }
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
            // mpv reports dozens of times a second; every change redraws whatever shows
            // the time. A quarter second is as smooth to the eye and far cheaper.
            if abs(t - self.position) >= 0.25 { self.position = t }
            if self.fadeInWhenPlaying {
                self.fadeInWhenPlaying = false
                self.fadeLevel = 0
                self.applyFade()
                if self.crossfading { self.fadeOutOutgoing(over: self.fadeSeconds) }
                self.fade(to: 1, over: self.crossfading ? self.fadeSeconds : 0.4, always: self.crossfading,
                          equalPower: self.crossfading)
                self.crossfading = false
            }
            self.planTransitionIfDue(at: t)
            self.prepareIncomingIfDue(at: t)
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

    private var nextSong: Song? {
        index + 1 < queue.count ? queue[index + 1] : repeatMode == .all ? queue.first : nil
    }

    private var transitionKey: String? {
        guard let a = current, let b = nextSong else { return nil }
        return a.id + ">" + b.id
    }

    /// 100 s before the end, listens to this song's end and the next one's start.
    /// Late on purpose: skipped songs and reshuffled queues cost nothing.
    private func planTransitionIfDue(at t: TimeInterval) {
        guard plansTransitions, !videoMode, repeatMode != .one, length > 30, t >= length - 100,
              let key = transitionKey, let a = current, let b = nextSong,
              transition?.key != key, planningKey != key else { return }
        guard smartTransitions else {
            // Gapless: no listening, the next song just starts as this one ends.
            transition = (key, TransitionPlan(outAt: max(0, length - 0.05), inAt: 0, fade: 0, onBeat: false))
            return
        }
        planningKey = key
        let length = length
        let fallback: TimeInterval = 5
        Task { @MainActor [weak self, resolver] in
            let plan = await TransitionStore.plan(from: a.id, length: length, to: b.id, fallbackFade: fallback) { id in
                guard let streams = try? await resolver.resolve(id, video: false) else { return nil }
                return (streams.audio, streams.availableAt)
            }
            guard let self, self.planningKey == key else { return }
            self.planningKey = nil
            guard let plan else { return TransitionStore.log.info("no plan for \(key, privacy: .public)") }
            self.transition = (key, plan)
            TransitionStore.log.info("\(key, privacy: .public): next at \(plan.outAt, format: .fixed(precision: 2)) of \(length, format: .fixed(precision: 0)), from \(plan.inAt, format: .fixed(precision: 2)), fade \(plan.fade, format: .fixed(precision: 2)), on beat \(plan.onBeat)")
        }
    }

    /// Next songs are loaded ahead for smart transitions, and for gapless playback
    /// when there's no crossfade. Not when the sleep timer stops at the song's end.
    private var plansTransitions: Bool {
        (smartTransitions || (gapless && crossfade == 0)) && sleepTimer != .endOfSong
    }

    /// Settings changed: forget the plan for the next song and make a new one.
    private func replan() {
        cancelPrepared()
        transition = nil
        planningKey = nil
    }

    /// Near the end of a song, starts the next one on the other engine and lets
    /// this one fade out underneath it. Not for videos, repeat-one, or short songs.
    private func startCrossfadeIfDue(at t: TimeInterval) {
        guard crossfade > 0 || plansTransitions, sleepTimer != .endOfSong, outgoing == nil, isPlaying, !videoMode, repeatMode != .one,
              index + 1 < queue.count || repeatMode == .all else { return }
        let plan = plansTransitions && transition?.key == transitionKey ? transition?.plan : nil
        if let p = prepared {
            // The pre-loaded song starts itself on the beat; only if it still isn't
            // ready half a second late does the ordinary crossfade take over.
            if p.key == transitionKey, let plan, t < plan.outAt + 0.5 { return }
            cancelPrepared()
        }
        // With smart transitions on, the Crossfade setting is unused.
        let seconds = plan?.fade ?? (smartTransitions ? 5 : crossfade)
        guard seconds > 0 || plan != nil else { return }
        guard (plan != nil ? length > seconds + 3 : length > seconds * 2 + 5),
              t >= (plan?.outAt ?? (length - seconds)) else { return }
        if let plan {
            TransitionStore.log.info("crossfade at \(t, format: .fixed(precision: 2)), planned \(plan.outAt, format: .fixed(precision: 2))")
        }
        let old = engine
        active = engines.firstIndex { $0 === otherEngine() } ?? active
        engine.set("mute", isMuted ? "yes" : "no")
        outgoing = old
        outgoingLevel = fadeLevel
        fadeSeconds = seconds
        crossfading = seconds > 0.05
        fadeLevel = seconds > 0.05 ? 0 : 1
        skipForward = true
        index = index + 1 < queue.count ? index + 1 : 0
        load(at: plan?.inAt ?? 0)
        if seconds <= 0.05 {
            fadeOutOutgoing(over: 0)
        }
    }

    /// Fades the outgoing song out once the incoming one is audible.
    /// Uses Spotify/Apple Music DJ curve for beat-matched mixes (retaining power under the intro,
    /// then fading sharply after the drop) or equal-power for natural fades.
    private func fadeOutOutgoing(over seconds: TimeInterval, matched: Bool = false) {
        guard let old = outgoing else { return }
        if seconds <= 0.05 {
            _ = old.trySet("ao-volume", "0.0")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishCrossfade(natural: true)
            }
            return
        }
        let from = outgoingLevel
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            let progress = min(1, Date().timeIntervalSince(began) / seconds)
            let curve = cos(smoothstep(progress) * .pi / 2)
            _ = old.trySet("ao-volume", String(format: "%.1f", from * curve * 100))
            if progress >= 1 {
                timer.invalidate()
                _ = old.trySet("ao-volume", "0.0")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.finishCrossfade(natural: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        outgoingTimer = timer
    }

    /// Stops the outgoing song: at the end of the fade, or at once when you skip,
    /// pause or pick something else mid-crossfade. Cut short, a beat-matched mix's
    /// speed and bass go straight back to normal; finished, the speed eases back.
    private func finishCrossfade(natural: Bool = false) {
        outgoingTimer?.invalidate()
        outgoingTimer = nil
        outgoing?.stop()
        outgoing?.resetTransition()
        outgoing = nil
        mix = nil
        if !natural {
            mixTimers.forEach { $0.invalidate() }
            mixTimers = []
            engine.resetTransition()
        }
    }

    /// The other engine, made the first time a crossfade needs it.
    private func otherEngine() -> MpvEngine {
        if engines.count == 1 {
            let second = MpvEngine()
            second.preset = eq.filter
            wire(second)
            engines.append(second)
        }
        return engines[1 - active]
    }

    /// Six seconds before a planned transition, loads the next song paused at its
    /// starting beat on the other engine, silent. Songs that would play as videos
    /// keep the ordinary crossfade.
    private func prepareIncomingIfDue(at t: TimeInterval) {
        if let p = prepared, p.key != transitionKey { cancelPrepared() }
        guard plansTransitions, prepared == nil, outgoing == nil, isPlaying, !videoMode,
              let key = transitionKey, let plan = transition?.plan, transition?.key == key,
              let b = nextSong, !(prefersVideo && b.hasVideo),
              t >= plan.outAt - 6, t < plan.outAt - 1.5 else {
            schedulePreparedStart(at: t)
            return
        }
        let incoming = otherEngine()
        incoming.resetTransition()
        incoming.set("volume", "0")
        _ = incoming.trySet("ao-volume", "0")
        incoming.set("mute", isMuted ? "yes" : "no")
        prepared = (key, incoming, 0, false)
        Task { @MainActor [weak self, resolver] in
            guard let streams = try? await resolver.resolve(b.id, video: false) else { return }
            let wait = streams.availableAt.timeIntervalSinceNow + 0.2
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, let p = self.prepared, p.key == key, p.engine === incoming else { return }
            self.prepared?.gain = streams.gainDb
            // The song that's leaving bends to the new one's tempo, not the other way
            // round: the new song then never has to change speed, which you'd hear.
            if plan.matched { self.rampSpeed(of: self.engine, to: 1 / plan.speed, over: 4) }
            incoming.load(audio: streams.audio, video: nil, start: plan.inAt, paused: true,
                          gainDb: self.matchLoudness ? streams.gainDb : 0)
        }
    }

    /// Within a second of the planned beat, sets a timer for that exact moment:
    /// waiting for the next position report would land tens of milliseconds off.
    private func schedulePreparedStart(at t: TimeInterval) {
        guard let p = prepared, p.ready, preparedStart == nil, p.key == transitionKey,
              let plan = transition?.plan, t >= plan.outAt - 1 else { return }
        let speed = max(0.5, engine.double("speed") ?? 1)
        let work = DispatchWorkItem { [weak self] in self?.startPrepared() }
        preparedStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, (plan.outAt - t) / speed - startLead), execute: work)
    }

    private func cancelPrepared() {
        preparedStart?.cancel()
        preparedStart = nil
        guard let p = prepared else { return }
        prepared = nil
        if outgoing == nil {
            mixTimers.forEach { $0.invalidate() }
            mixTimers = []
            engine.set("speed", "1")
        }
        if p.engine !== engine {
            p.engine.stop()
            p.engine.resetTransition()
        }
    }

    /// The planned beat: the pre-loaded song starts, both fade on equal-power curves,
    /// and in a beat-matched mix the bass swaps halfway.
    private func startPrepared() {
        preparedStart = nil
        guard let p = prepared, p.ready, p.key == transitionKey, let plan = transition?.plan,
              isPlaying, outgoing == nil, !videoMode,
              let slot = engines.firstIndex(where: { $0 === p.engine }), let song = nextSong else {
            return cancelPrepared()
        }
        prepared = nil
        let old = engine
        let from = current
        outgoing = old
        outgoingLevel = fadeLevel
        fadeTimer?.invalidate()
        fadeLevel = 0
        active = slot
        applyVolume()
        p.engine.set("pause", "no")
        // In real seconds: the outgoing song runs at its bent tempo during the mix.
        let seconds = plan.matched ? plan.fade * plan.speed : plan.fade
        fadeSeconds = seconds
        if let from, seconds >= Self.minimumMix { mix = Mix(from: from, began: Date(), seconds: seconds) }
        crossfading = false
        skipForward = true
        index = index + 1 < queue.count ? index + 1 : 0
        // What load() would have set up for the new song, without loading it again.
        loadToken += 1
        reportedPlay = nil
        needsLoad = false
        isLoading = false
        isPlaying = true
        awaitingFile = false
        fadeInWhenPlaying = false
        advancingNaturally = false
        position = plan.inAt
        livePosition = plan.inAt
        duration = p.engine.double("duration") ?? song.duration
        lastError = nil
        currentGain = p.gain
        warmNeighbourCovers()
        publishNowPlaying()
        Task { @MainActor [weak self] in await self?.afterTrackStarted(video: false, height: self?.videoQuality ?? 1080) }
        if seconds <= 0.05 {
            fadeLevel = 1.0
            applyVolume()
            fadeOutOutgoing(over: 0, matched: false)
        } else {
            fade(to: 1, over: seconds, always: true, equalPower: true, matched: plan.matched)
            fadeOutOutgoing(over: seconds, matched: plan.matched)
        }
        // EQ automation, styled after Apple Music / Spotify Automix:
        let incoming = p.engine
        if plan.matched {
            let swapTime = plan.swapDelay ?? (seconds / 2)
            // Incoming sizzle opens smoothly over the intro before the drop
            ramp(after: 0, over: swapTime) { incoming.setHighs(-8 * (1 - $0)) }
            // The bass swap lands right on the downbeat drop over 1 beat
            let swapDuration = min(0.8, max(0.25, plan.beat * plan.speed))
            ramp(after: max(0, swapTime - swapDuration * 0.2), over: swapDuration) {
                incoming.setBass(-24 * (1 - $0))
                old.setBass(-24 * $0)
            }
            // Outgoing sizzle filters down gently after the drop (preserving vocal presence)
            let remaining = max(0.5, seconds - swapTime)
            ramp(after: swapTime, over: remaining) { old.setHighs(-10 * $0) }
        } else if plan.onBeat {
            // Tempos too far apart to match: the new song comes in thin (no bass, soft
            // highs) under the old one, the bass swaps over two beats halfway, and the
            // old song's highs roll away in the second half, so the two kicks never clash.
            let swapTime = plan.swapDelay ?? seconds / 2
            let swapDuration = max(0.5, min(1.5, plan.beat * 2))
            incoming.setBass(-24)
            incoming.setHighs(-8)
            old.setBass(0)
            old.setHighs(0)
            ramp(after: 0, over: swapTime) { incoming.setHighs(-8 * (1 - $0)) }
            ramp(after: max(0, swapTime - swapDuration / 2), over: swapDuration) {
                incoming.setBass(-24 * (1 - $0))
                old.setBass(-24 * $0)
            }
            ramp(after: swapTime, over: max(0.5, seconds - swapTime)) { old.setHighs(-12 * $0) }
        } else {
            // Rubato / Piano / Acoustic: Transparent natural sound at 0 dB
            old.setBass(0)
            old.setHighs(0)
            incoming.setBass(0)
            incoming.setHighs(0)
        }
        // How far apart the two songs' beats really landed (both started on a beat).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let a = old.double("time-pos"), let b = p.engine.double("time-pos") else { return }
            let offset = ((a - plan.outAt) * plan.speed - (b - plan.inAt)) * 1000
            // Positive: the new song was heard late. Fold that into the next start.
            if let self, abs(offset) < 300 {
                self.startLead = min(0.25, max(0, self.startLead + 0.5 * offset / 1000))
                Prefs.set(self.startLead, "mixStartLead")
            }
            TransitionStore.log.info("mix started, beats \(offset, format: .fixed(precision: 0)) ms apart, speed \(plan.speed, format: .fixed(precision: 3)), matched \(plan.matched), next lead \((self?.startLead ?? 0) * 1000, format: .fixed(precision: 0)) ms")
        }
    }

    /// Runs `apply` from 0 to 1 over `seconds`, starting after `delay`. Part of the
    /// mix, so cutting the mix short stops it.
    private func ramp(after delay: TimeInterval, over seconds: TimeInterval, apply: @escaping (Double) -> Void) {
        let start = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            let began = Date()
            let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { timer in
                let p = min(1, Date().timeIntervalSince(began) / max(0.05, seconds))
                apply(p)
                if p >= 1 { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self?.mixTimers.append(timer)
        }
        RunLoop.main.add(start, forMode: .common)
        mixTimers.append(start)
    }

    /// Bends a song's tempo in small steps (pitch stays: mpv's scaletempo2).
    private func rampSpeed(of e: MpvEngine, to target: Double, over seconds: Double) {
        let from = e.double("speed") ?? 1
        let began = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            let p = min(1, Date().timeIntervalSince(began) / seconds)
            e.set("speed", String(format: "%.4f", from + (target - from) * p))
            if p >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mixTimers.append(timer)
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
        guard index >= queue.count - 2, let seed = current else { return }
        // A mood keeps going under Repeat All too; otherwise it wraps back to old songs.
        if mood != nil, repeatMode != .one { return extendMood() }
        guard autoplay, repeatMode == .off else { return }
        appendRadio(after: seed)
    }

    // MARK: Mood

    /// Replaces Up Next with songs for `prompt` and keeps it going from there.
    /// The song playing keeps playing. With nothing playing (stopped, paused, or only
    /// last session's song, not loaded yet), the mood's first song starts.
    func startMood(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let moodSongs else { return }
        moodGeneration += 1
        let generation = moodGeneration
        withAnimation(.snappy) { moodLoading = prompt }
        Task { @MainActor [weak self] in
            let songs = await moodSongs(prompt)
            guard let self, self.moodGeneration == generation else { return }
            withAnimation(.snappy) { self.moodLoading = nil }
            guard !songs.isEmpty else { return }
            let batch = Array(songs.prefix(10))
            if self.current == nil || self.needsLoad {
                self.play(batch[0], in: batch)
            } else {
                self.unshuffledUpNext = nil
                withAnimation(.snappy) {
                    self.queue = Array(self.queue[...self.index])
                    self.appendDeduped(batch)
                }
                if !self.isPlaying, !self.isLoading, !self.upNext.isEmpty { self.jump(to: self.index + 1) }
            }
            withAnimation(.snappy) { self.mood = prompt }
            self.moodGeneration = generation
            self.moodPool = Array(songs.dropFirst(10))
            self.publishNowPlaying()
            await self.resolver.prepare(self.upNext.prefix(2).map(\.id), video: self.videoMode, maxHeight: self.videoQuality)
        }
    }

    /// Up Next goes back to the radio once the mood's songs run out.
    func endMood() {
        withAnimation(.snappy) {
            mood = nil
            moodLoading = nil
        }
        moodPool = []
        moodGeneration += 1
    }

    /// Tops up Up Next from the mood's songs; once those are used up, from the
    /// radio of a song the mood played, which stays close to it.
    private func extendMood() {
        let before = queue.count
        while queue.count == before, !moodPool.isEmpty {
            appendDeduped(Array(moodPool.prefix(10)))
            moodPool.removeFirst(min(10, moodPool.count))
        }
        if queue.count > before { return publishNowPlaying() }
        guard let radio, let seed = queue.suffix(10).randomElement() else { return }
        let generation = moodGeneration
        Task { @MainActor [weak self] in
            let songs = await radio(seed)
            guard let self, self.moodGeneration == generation else { return }
            self.appendDeduped(songs)
            self.publishNowPlaying()
            await self.resolver.prepare(self.upNext.prefix(2).map(\.id), video: self.videoMode, maxHeight: self.videoQuality)
        }
    }

    /// Plays a song followed by its radio, as YouTube Music does for songs on Home.
    /// The song already playing keeps playing; only what comes after it changes.
    func playRadio(_ song: Song) {
        endMood()
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
            self.appendDeduped(songs)
            // The radio usually arrives after the song's own load queued nothing next.
            await self.resolver.prepare(self.upNext.prefix(2).map(\.id), video: self.videoMode, maxHeight: self.videoQuality)
        }
    }

    /// Adds radio songs, skipping any whose title is already queued (the uploaded
    /// video and the album track of one song). A song track replaces a queued video.
    private func appendDeduped(_ songs: [Song]) {
        var seen: [String: Int] = [:]
        for (i, song) in queue.enumerated() { seen[Self.titleKey(song.title)] = i }
        for song in songs where !queue.contains(where: { $0.id == song.id }) {
            let key = Self.titleKey(song.title)
            if let i = seen[key] {
                if i > index, queue[i].hasVideo, !song.hasVideo { queue[i] = song }
                continue
            }
            seen[key] = queue.count
            queue.append(song)
        }
    }

    /// A title without case, punctuation or bracketed parts like "(Official Video)".
    private static func titleKey(_ title: String) -> String {
        let bare = title.replacingOccurrences(of: #"[\(\[【「].*?[\)\]】」]"#, with: "", options: .regularExpression)
        let key = String(bare.lowercased().filter { $0.isLetter || $0.isNumber })
        return key.isEmpty ? String(title.lowercased().filter { $0.isLetter || $0.isNumber }) : key
    }

    /// Resolves the current track's streams (cached or prefetched when possible)
    /// and hands them to mpv. A newer load cancels an older one still resolving.
    /// `followLive`: the same track as another kind (song to video, a new quality).
    /// It keeps playing while the new streams load, so the switch picks up from
    /// wherever it has got to by then instead of jumping back.
    /// Decodes the covers a skip or swipe shows next, at the player bar's and Now
    /// Playing's sizes, so the new song never flashes the placeholder.
    private func warmNeighbourCovers() {
        let urls = [upNext.first, played.last].compactMap { $0?.artwork }
        Task.detached(priority: .utility) {
            for url in urls {
                for side: CGFloat in [52, 340] { _ = await ImageDecodeCache.shared.image(url, maxPixelSize: side * 2) }
            }
        }
    }

    /// Once a song is playing, by a load or a pre-loaded mix: remember the session,
    /// top up the radio, and get the next songs ready.
    private func afterTrackStarted(video: Bool, height: Int) async {
        saveSession()
        extendWithRadioIfNeeded()
        // The next two are songs you're about to hear, so they don't wait in line
        // behind songs you hovered; the third goes in the background line.
        await resolver.prepare(upNext.prefix(2).map(\.id), video: video, maxHeight: height)
        await resolver.prefetch(upNext.dropFirst(2).prefix(1).map(\.id), video: video, maxHeight: height)
    }

    private func load(at start: TimeInterval = 0, autoplay: Bool = true, followLive: Bool = false) {
        cancelPrepared()
        if !followLive {
            mixTimers.forEach { $0.invalidate() }
            mixTimers = []
        }
        guard let song = current else {
            engine.stop()
            return
        }
        loadToken += 1
        let token = loadToken
        reportedPlay = nil
        warmNeighbourCovers()
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
        pendingSeek = nil
                let begin = followLive ? self.livePosition + 0.2 : start
                self.position = begin
                if !followLive { self.engine.resetTransition() }
                self.engine.load(audio: streams.audio, video: streams.video, start: begin, paused: !autoplay,
                                 gainDb: self.matchLoudness ? streams.gainDb : 0)
                self.isLoading = false
                await self.afterTrackStarted(video: video, height: height)
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
        endMood()
        unshuffledUpNext = nil
        if shuffle {
            let rest = list.enumerated().filter { $0.offset != first }.map(\.element)
            unshuffledUpNext = rest
            list = [song] + rest.shuffled()
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

    /// Play turns shuffle off and Shuffle turns it on, as in YouTube Music.
    func playAll(_ songs: [Song], shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        settingShuffle = true
        shuffle = shuffled
        settingShuffle = false
        play(shuffled ? songs.randomElement()! : songs[0], in: songs)
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
        if sleepTimer == .endOfSong, repeatMode != .one {
            // Stop here, with the next song lined up for when you press play.
            sleepTimer = .off
            isPlaying = false
            if index + 1 < queue.count { index += 1 } else if repeatMode == .all { index = 0 }
            position = 0
            needsLoad = true
            publishNowPlaying()
            return
        }
        advancingNaturally = true
        if repeatMode == .one { load() } else { next() }
    }

    /// Ramps the volume between silent (0) and the slider's level (1), then runs `done`.
    /// `always`: fade even with smooth transitions off (a crossfade).
    private func fade(to target: Double, over seconds: Double, always: Bool = false, equalPower: Bool = false,
                      matched: Bool = false, then done: (() -> Void)? = nil) {
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
            let shaped: Double
            if matched || equalPower {
                // Eased at both ends: plain sin rises steeply at the start, and the
                // new song jumps in.
                shaped = sin(smoothstep(progress) * .pi / 2)
            } else {
                shaped = progress
            }
            self.fadeLevel = from + (target - from) * shaped
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
        livePosition = time
        if isLoading || awaitingFile { pendingSeek = time } else { engine.seek(time) }
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
        endMood()
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

/// Eases in and out (slow at both ends): crossfades shaped with it neither lurch
/// in nor drop away.
func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }

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
    /// The song whose Song Info sheet is open.
    var infoSong: Song?
    var backStack: [Route] = []
    var forwardStack: [Route] = []
    var showNowPlaying = false
    var panelVisible = false
    var panelTab = PanelTab.queue
    /// Lyrics / Up Next beside the cover in Now Playing; off leaves the cover alone.
    var nowPlayingPanel = Prefs.bool("nowPlayingPanel", true) {
        didSet { Prefs.set(nowPlayingPanel, "nowPlayingPanel") }
    }

    var videoFullscreen = false
    var showShortcuts = false
    /// Bumped by / and ⌘K so the search field takes focus even when Search is already open.
    var searchFocusRequest = 0
    var showPalette = false
    /// The floating video in the corner was closed for the current video session.
    var miniPlayerHidden = false

    @ObservationIgnored var pointerOverShelf = false
    @ObservationIgnored var pointerOverPlayerSong = false
    @ObservationIgnored var pointerOverProgress = false
    @ObservationIgnored var pointerOverPlayerBar = false
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

/// Two-finger horizontal swipes: over the player's song they skip tracks, over the
/// progress bar they seek, elsewhere they go back/forward like Safari. Shelves keep
/// their own scrolling. Scrolling up or down over the player bar or Now Playing's
/// cover sets the volume.
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
        guard e.momentumPhase.isEmpty else { return }
        // A seek swipe lands when the fingers lift, wherever the pointer is by then.
        if let target = player.scrubPosition, e.phase == .ended || e.phase == .cancelled {
            player.seek(target)
            player.scrubPosition = nil
            return
        }
        if router.pointerOverPlayerSong || router.pointerOverPlayerBar, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) {
            // Fingers or wheel up is louder. A wheel notch is 5%, a trackpad swipe smooth.
            let up = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
            player.volume = min(1, max(0, player.volume + up * (e.hasPreciseScrollingDeltas ? 0.004 : 0.05)))
            return
        }
        guard e.hasPreciseScrollingDeltas else { return }
        if router.pointerOverProgress {
            guard player.length > 0, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
            // Fingers right moves forward; a full swipe covers roughly a fifth of the song.
            // The bar follows every event; the audio seeks once, when the fingers lift.
            let forward = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            let from = player.scrubPosition ?? player.position
            player.scrubPosition = min(player.length, max(0, from + forward * max(0.1, player.length / 1500)))
            return
        }
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
        case "s": withAnimation(.snappy(duration: 0.45)) { player.shuffle.toggle() }
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
