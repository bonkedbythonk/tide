import AppKit
import SwiftUI


enum RepeatMode: String { case off, all, one }

enum Prefs {
    private static let d = UserDefaults.standard
    static func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
    static func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
    static func bool(_ key: String, _ fallback: Bool = false) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
    static func string(_ key: String) -> String? { d.string(forKey: key) }
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
    var isMuted = false { didSet { engine.set("mute", isMuted ? "yes" : "no") } }
    var repeatMode = RepeatMode(rawValue: Prefs.string("repeat") ?? "") ?? .off {
        didSet { Prefs.set(repeatMode.rawValue, "repeat") }
    }
    var crossfade = 0.0
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
    var device = "This Mac"
    var skipForward = true
    /// Song or music video for the current track (Pear's video-toggle). Switching
    /// reloads the track as the other kind, from the same moment.
    var videoMode = false {
        didSet {
            guard oldValue != videoMode, !settingVideoForNewQueue, current != nil else { return }
            load(at: position, autoplay: isPlaying)
        }
    }

    /// Highest video resolution to ask for (Pear's quality-changer).
    var videoQuality = Prefs.int("videoQuality", 1080) {
        didSet {
            Prefs.set(videoQuality, "videoQuality")
            guard oldValue != videoQuality, videoMode, current != nil else { return }
            load(at: position, autoplay: isPlaying)
        }
    }

    /// Fade the volume on pause, resume and skips instead of cutting (your smooth-transitions plugin).
    var smoothTransitions = Prefs.bool("smoothTransitions", true) {
        didSet { Prefs.set(smoothTransitions, "smoothTransitions") }
    }

    @ObservationIgnored let engine = MpvEngine()
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
        engine.onFileLoaded = { [weak self] in self?.awaitingFile = false }
        engine.onTime = { [weak self] t in
            guard let self, !self.isLoading, !self.awaitingFile else { return }
            self.position = t
            if self.fadeInWhenPlaying {
                self.fadeInWhenPlaying = false
                self.fadeLevel = 0
                self.applyFade()
                self.fade(to: 1, over: 0.4)
            }
        }
        engine.onDuration = { [weak self] d in
            guard let self, !self.awaitingFile else { return }
            self.duration = d
            self.publishNowPlaying()
        }
        engine.onPause = { [weak self] paused in
            guard let self, !self.isLoading, self.current != nil else { return }
            self.isPlaying = !paused
            self.publishNowPlaying()
        }
        engine.onEnded = { [weak self] in self?.trackEnded() }
        engine.onError = { [weak self] message in
            self?.lastError = "Playback failed: \(message)"
            self?.isPlaying = false
        }
        applyVolume()
        nowPlaying = NowPlayingCenter(player: self)
    }

    /// Resolves the current track's streams (cached or prefetched when possible)
    /// and hands them to mpv. A newer load cancels an older one still resolving.
    private func load(at start: TimeInterval = 0, autoplay: Bool = true) {
        guard let song = current else {
            engine.stop()
            return
        }
        loadToken += 1
        let token = loadToken
        let fadeIn = smoothTransitions && !advancingNaturally
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
                self.engine.load(audio: streams.audio, video: streams.video, start: start, paused: !autoplay,
                                 gainDb: self.matchLoudness ? streams.gainDb : 0)
                self.isLoading = false
                await self.resolver.prefetch(self.upNext.prefix(10).map(\.id), video: video, maxHeight: height)
            } catch {
                guard token == self.loadToken else { return }
                self.fade(to: 0, over: 0.2) { [weak self] in self?.engine.set("pause", "yes") }
                self.isLoading = false
                self.isPlaying = false
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Starts resolving a song the pointer rests on, so a click on it starts sooner.
    func prefetch(_ song: Song, video: Bool = false) {
        let height = videoQuality
        Task { await resolver.prefetch([song.id], video: video, maxHeight: height) }
    }

    func play(_ song: Song, in list: [Song], video: Bool = false, at start: TimeInterval = 0) {
        var list = list.isEmpty ? [song] : list
        var first = list.firstIndex(of: song) ?? 0
        if shuffle {
            list = [song] + list.enumerated().filter { $0.offset != first }.map(\.element).shuffled()
            first = 0
        }
        settingVideoForNewQueue = true
        videoMode = video
        settingVideoForNewQueue = false
        skipForward = true
        queue = list
        index = first
        load(at: start)
    }

    func playAll(_ songs: [Song], shuffled: Bool = false, video: Bool = false) {
        guard !songs.isEmpty else { return }
        let list = shuffled ? songs.shuffled() : songs
        play(list[0], in: list, video: video)
    }

    func resume(_ song: Song, at time: TimeInterval) {
        play(song, in: [song], at: time)
    }

    func jump(to queueIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        skipForward = queueIndex > index
        index = queueIndex
        load()
    }

    func toggle() {
        guard current != nil else { return }
        if lastError != nil { return load(at: position) }
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
        }
        publishNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
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
    private func fade(to target: Double, over seconds: Double, then done: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard smoothTransitions, seconds > 0 else {
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

    private func publishNowPlaying() { nowPlaying?.update(song: current, position: position, duration: length, playing: isPlaying) }
}

/// Home section order and visibility, by section title, kept between launches.
@Observable final class HomeConfig {
    var order: [String] = UserDefaults.standard.stringArray(forKey: "homeOrder") ?? [] {
        didSet { UserDefaults.standard.set(order, forKey: "homeOrder") }
    }
    var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "homeHidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "homeHidden") }
    }
    var showContinueBanner = true

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
        showContinueBanner = true
    }
}

@Observable final class Router {
    var current = Route.home
    var backStack: [Route] = []
    var forwardStack: [Route] = []
    var showNowPlaying = false
    var panelVisible = false
    var panelTab = PanelTab.queue

    var videoFullscreen = false
    var showShortcuts = false
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
        case "n": if player.current != nil { withAnimation(.spring(duration: 0.45, bounce: 0.12)) { router.showNowPlaying.toggle() } }
        case "l": router.togglePanel(.lyrics)
        case "q": router.togglePanel(.queue)
        case "/": router.go(.search)
        default: return false
        }
        return true
    }

    static let list: [(String, String)] = [
        ("Space", "Play / pause"), ("← →", "Back / forward 5 seconds"), ("↑ ↓", "Volume"),
        ("⌘← ⌘→", "Previous / next song"), ("M", "Mute"), ("S", "Shuffle"), ("R", "Repeat"),
        ("V", "Song / music video"), ("F", "Fullscreen video"), ("N", "Now Playing"),
        ("L", "Lyrics"), ("Q", "Up Next"), ("⌘L", "Like"),
        ("⌘1 – ⌘9", "Home, Search, Liked, Albums, playlists"), ("⌘K or /", "Search"),
        ("⌘[ ⌘]  or  ⌥← ⌥→", "Back / forward"), ("⌘,", "Settings"), ("?", "This list"),
    ]
}
