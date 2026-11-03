import AppKit
import SwiftUI

@main
struct MusicSampleApp: App {
    @State private var library = Library()
    @State private var player = Player()
    @State private var router = Router()
    @State private var home = HomeConfig()
    @State private var lyrics = LyricsStore()
    @State private var wallpaper = WallpaperStore()

    /// ⌘1–⌘9: the fixed sections, then your playlists in sidebar order.
    private var goTargets: [(String, Route)] {
        [("Home", .home), ("Search", .search), ("Liked Songs", .liked), ("Library", .library),
         ("History", .history)]
            + library.playlists.map { ($0.title, Route.page($0.id)) }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        _ = ResponsiveScrollingPatch.applyOnce
    }

    var body: some Scene {
        WindowGroup("Tide") {
            RootView()
                .environment(library)
                .environment(player)
                .environment(router)
                .environment(home)
                .environment(lyrics)
                .environment(wallpaper)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1280, height: 820)
        // No top bar, like anicat: content runs to the top edge and the window
        // buttons sit over the sidebar.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Settings is a page in the window, not a separate settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { router.go(.settings) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Playback") {
                // Space and the other single keys are handled by KeyboardShortcuts (press ?).
                Button(player.isPlaying ? "Pause  (Space)" : "Play  (Space)") { player.toggle() }
                Button("Next Song") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Song") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Like Current Song") {
                    if let s = player.current { library.toggleLike(s.id) }
                }
                .keyboardShortcut("l", modifiers: .command)
                Button("Now Playing") { withAnimation(.spring(duration: 0.45, bounce: 0)) { router.showNowPlaying.toggle() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Lyrics") { router.togglePanel(.lyrics) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Up Next") { router.togglePanel(.queue) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Back") { router.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button("Forward") { router.goForward() }.keyboardShortcut("]", modifiers: .command)
                Divider()
                ForEach(Array(goTargets.prefix(9).enumerated()), id: \.offset) { i, target in
                    Button(target.0) { router.go(target.1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Divider()
                Button("Search…") { router.openSearch() }
                Button("Command Palette…") { withAnimation(.snappy(duration: 0.2)) { router.showPalette.toggle() } }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Keyboard Shortcuts") { router.showShortcuts.toggle() }
            }
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(\.colorScheme) private var colorScheme
    @State private var canvasSize = CGSize.zero
    @Environment(Router.self) private var router
    @State private var swipe = SwipeTracker()

    private var content: some View {
        ZStack {
            // Floating draws the wallpaper once behind the window instead (FrameShade).
            if !wallpaper.isActive { WallpaperBackground() }
            DetailView()
                .environment(\.colorScheme, wallpaper.isActive ? .dark : colorScheme)
            if router.showNowPlaying {
                NowPlayingView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.22), value: router.current)
        .inspector(isPresented: Binding(
            get: { router.panelVisible && !router.showNowPlaying },
            set: { router.panelVisible = $0 }
        )) {
            SidePanelView()
                .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
                .environment(\.colorScheme, wallpaper.isActive ? .dark : colorScheme)
        }
        .overlay(alignment: .topLeading) {
            if !router.showNowPlaying {
                HStack(spacing: 6) {
                    NavCircleButton(symbol: "chevron.left", enabled: !router.backStack.isEmpty) { router.goBack() }
                        .help("Back (swipe right with two fingers)")
                    NavCircleButton(symbol: "chevron.right", enabled: !router.forwardStack.isEmpty) { router.goForward() }
                        .help("Forward")
                }
                .padding(.leading, 14)
                .padding(.top, 10)
                .environment(\.colorScheme, wallpaper.isActive ? .dark : colorScheme)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if wallpaper.isActive {
                    // Over a wallpaper: our own side-by-side layout of floating panels (the
                    // system split view draws a divider seam that can't be styled away).
                    // The panels are see-through; FrameShade behind them darkens the rest.
                    HStack(spacing: 0) {
                        SidebarView()
                            .frame(width: PanelStyle.sidebarWidth)
                            .padding([.leading, .top, .bottom], PanelStyle.margin)
                            // Up to the window's top edge, window buttons inside the panel.
                            .ignoresSafeArea(.container, edges: .top)
                            .environment(\.colorScheme, .dark)
                        content
                            .clipShape(RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous))
                            .padding(PanelStyle.margin)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                } else {
                    NavigationSplitView {
                        SidebarView()
                            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
                    } detail: {
                        content
                    }
                }
            }
            if !wallpaper.isActive { Divider() }
            PlayerBar()
        }
        .background {
            // The one wallpaper for the whole window, darkened outside the panels.
            if wallpaper.isActive {
                ZStack {
                    WallpaperBackground()
                    FrameShade()
                    WindowButtonsLowered()
                }
                // Into the title-bar strip too, which otherwise showed lighter.
                .ignoresSafeArea()
            }
        }
        .background {
            // Reports the window's size so every wallpaper slice lines up.
            GeometryReader { proxy in
                Color.clear.preference(key: CanvasSizeKey.self, value: proxy.size)
            }
            .ignoresSafeArea()
        }
        // Over a wallpaper the whole window is dark, the system-drawn dividers included.
        .preferredColorScheme(wallpaper.isActive ? .dark : nil)
        .onPreferenceChange(CanvasSizeKey.self) { canvasSize = $0 }
        .environment(\.wallpaperCanvas, canvasSize)
        .overlay(alignment: .bottomTrailing) {
            if player.videoMode, player.current != nil, !router.showNowPlaying, !router.videoFullscreen,
               !router.miniPlayerHidden {
                VideoMiniPlayer()
                    .padding(.trailing, 20)
                    .padding(.bottom, 96)
                    .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0), value: router.showNowPlaying)
        .onChange(of: player.videoMode) { _, on in if on { router.miniPlayerHidden = false } }
        .overlay {
            if router.videoFullscreen {
                VideoFullscreenView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.videoFullscreen)
        .overlay(alignment: .bottom) {
            if let toast = library.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if router.showPalette {
                CommandPalette().transition(.opacity)
            }
        }
        .alert(router.prompt?.title ?? "", isPresented: Binding(get: { router.prompt != nil },
                                                                set: { if !$0 { router.prompt = nil } })) {
            TextField("Name", text: Binding(get: { router.prompt?.text ?? "" }, set: { router.prompt?.text = $0 }))
            Button(router.prompt?.button ?? "OK") {
                if let p = router.prompt {
                    let text = p.text.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { p.done(text) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { router.showShortcuts }, set: { router.showShortcuts = $0 })) {
            ShortcutsSheet()
        }
        .onAppear {
            swipe.install(router: router, player: player)
            KeyboardShortcuts.install(player: player, router: router)
            player.radio = { [library] in await library.radio(after: $0) }
            player.latest = { [library] in library.song($0) }
            player.reportPlay = { [library] in await library.client.addToHistory($0.id) }
            if Demo.isOn { Demo.open(UserDefaults.standard.string(forKey: "demoScreen"), router: router) }
        }
        .task { await library.start() }
        // Signed in (cookies written), before the library refresh finishes.
        .onChange(of: library.state) { old, new in
            if old == .starting, new == .ready || new == .loading { Task { await player.prepareRestored() } }
        }
        // Warms the yt-dlp worker on something you're likely to play anyway.
        .onChange(of: library.home.first?.songs.first?.id, initial: true) {
            if let song = library.home.first?.songs.first { player.prefetch(song) }
        }
        // Lyrics load with every song, so Now Playing knows up front whether there are any.
        .onChange(of: player.current?.id, initial: true) { wallpaper.songChanged(cover: player.current?.artwork) }
        .task(id: player.current?.id) {
            guard let song = player.current else { return }
            for _ in 0..<15 where player.duration <= 0 { try? await Task.sleep(for: .milliseconds(200)) }
            await lyrics.load(song, duration: player.duration)
        }
    }
}

struct DetailView: View {
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            switch library.state {
            case .starting, .loading:
                ProgressView("Loading your music…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignedOutView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load YouTube Music", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await library.refresh() } }
                    Button("Sign In Again") { Task { await library.signOut() } }
                }
            case .ready:
                switch router.current {
                case .home: HomeView()
                case .search: SearchView()
                case .library: LibraryView()
                case .history: PageView(id: Library.historyID)
                case .liked: PageView(id: Library.likedID)
                case .settings: SettingsPage()
                case .page(let id): PageView(id: id)
                }
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity
        ))
        .id(router.current)
        .navigationTitle(title)
    }

    private var title: String {
        switch router.current {
        case .home: "Home"
        case .search: "Search"
        case .liked: "Liked Songs"
        case .library: "Library"
        case .history: "History"
        case .settings: "Settings"
        case .page(let id): library.pages[id]?.title ?? ""
        }
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                ForEach(KeyboardShortcuts.list, id: \.0) { keys, action in
                    GridRow {
                        Text(keys).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                        Text(action).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Single keys don't fire while you're typing in a field.")
                .font(.caption).foregroundStyle(.tertiary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 440)
    }
}

private struct CanvasSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}



/// The floating back/forward buttons that replace the top bar.
struct NavCircleButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}
