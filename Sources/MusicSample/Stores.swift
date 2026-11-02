import AppKit
import SwiftUI


enum RepeatMode { case off, all, one }

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat", bass = "Bass boost", vocal = "Vocal", treble = "Treble boost", night = "Late night"
    var id: String { rawValue }
}

enum SleepTimer: String, CaseIterable, Identifiable {
    case off = "Off", m15 = "15 minutes", m30 = "30 minutes", h1 = "1 hour", endOfSong = "End of song"
    var id: String { rawValue }
}

/// Fake playback: a timer moves the position so the UI behaves like a real player.
@Observable final class Player {
    var queue: [Song] = []
    var index = 0
    var isPlaying = false
    var position: TimeInterval = 0
    var volume = 0.7
    var shuffle = false
    var repeatMode = RepeatMode.off
    var crossfade = 0.0
    var gapless = true
    var eq = EQPreset.flat
    var normalize = true
    var sleepTimer = SleepTimer.off
    var device = "This Mac"
    var skipForward = true
    /// Song or music video for the current track (Pear's video-toggle).
    var videoMode = false

    @ObservationIgnored private var timer: Timer?

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Song] { queue.indices.contains(index) ? Array(queue[(index + 1)...]) : [] }

    init() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard isPlaying, let song = current else { return }
        position += 0.25
        if position >= song.playDuration {
            if repeatMode == .one { position = 0 } else { next() }
        }
    }

    func play(_ song: Song, in list: [Song], video: Bool = false) {
        videoMode = video
        var list = list.isEmpty ? [song] : list
        var start = list.firstIndex(of: song) ?? 0
        if shuffle {
            list = [song] + list.enumerated().filter { $0.offset != start }.map(\.element).shuffled()
            start = 0
        }
        skipForward = true
        queue = list
        index = start
        position = 0
        isPlaying = true
    }

    func playAll(_ songs: [Song], shuffled: Bool = false, video: Bool = false) {
        guard !songs.isEmpty else { return }
        let list = shuffled ? songs.shuffled() : songs
        play(list[0], in: list, video: video)
    }

    func resume(_ song: Song, at time: TimeInterval) {
        play(song, in: [song])
        position = time
    }

    func jump(to queueIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        skipForward = queueIndex > index
        index = queueIndex
        position = 0
        isPlaying = true
    }

    func toggle() {
        guard current != nil else { return }
        isPlaying.toggle()
    }

    func next() {
        guard !queue.isEmpty else { return }
        skipForward = true
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            isPlaying = false
        }
        position = 0
    }

    func previous() {
        guard !queue.isEmpty else { return }
        skipForward = false
        if position > 3 || index == 0 {
            position = 0
        } else {
            index -= 1
            position = 0
        }
    }

    func seek(_ time: TimeInterval) { position = time }

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
