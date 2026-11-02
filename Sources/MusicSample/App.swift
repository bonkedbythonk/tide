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
        [("Home", .home), ("Search", .search), ("Liked Songs", .liked), ("Saved Albums", .savedAlbums)]
            + library.playlists.map { ($0.title, Route.page($0.id)) }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        _ = ResponsiveScrollingPatch.applyOnce
    }

    var body: some Scene {
        WindowGroup("Music Sample") {
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
        Settings {
            SettingsView().environment(wallpaper)
        }
        .commands {
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
                Button("Now Playing") { withAnimation(.snappy) { router.showNowPlaying.toggle() } }
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
                Button("Search…") { router.go(.search) }.keyboardShortcut("k", modifiers: .command)
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
            WallpaperBackground()
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
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { router.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(router.backStack.isEmpty && !router.showNowPlaying)
                    .help("Back (swipe right with two fingers)")
                Button { router.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(router.forwardStack.isEmpty)
                    .help("Forward")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if wallpaper.isActive {
                    // Over a wallpaper: our own side-by-side layout. The system split
                    // view draws a divider seam that can't be styled away.
                    HStack(spacing: 0) {
                        SidebarView()
                            .frame(width: 230)
                            .background {
                                ZStack {
                                    WallpaperBackground()
                                    Rectangle().fill(.ultraThinMaterial)
                                }
                                .ignoresSafeArea()
                            }
                            .environment(\.colorScheme, .dark)
                        content
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
            .toolbar(router.videoFullscreen ? .hidden : .automatic, for: .windowToolbar)
            if !wallpaper.isActive { Divider() }
            PlayerBar()
        }
        .background {
            // Reports the window's size so every wallpaper slice lines up.
            GeometryReader { proxy in
                Color.clear.preference(key: CanvasSizeKey.self, value: proxy.size)
            }
            .ignoresSafeArea()
        }
        .onPreferenceChange(CanvasSizeKey.self) { canvasSize = $0 }
        // Over a wallpaper the top bar keeps its blurred background (so scrolled content
        // doesn't run into the title) but loses the line under it.
        .onChange(of: wallpaper.isActive, initial: true) { _, on in
            DispatchQueue.main.async {
                for window in NSApp.windows { window.titlebarSeparatorStyle = on ? .none : .automatic }
            }
        }
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
        .animation(.spring(duration: 0.4, bounce: 0.15), value: router.showNowPlaying)
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
        .sheet(isPresented: Binding(get: { router.showShortcuts }, set: { router.showShortcuts = $0 })) {
            ShortcutsSheet()
        }
        .onAppear {
            swipe.install(router: router, player: player)
            KeyboardShortcuts.install(player: player, router: router)
        }
        .task { await library.start() }
        // Warms the yt-dlp worker on something you're likely to play anyway.
        .onChange(of: library.home.first?.songs.first?.id, initial: true) {
            if let song = library.home.first?.songs.first { player.prefetch(song) }
        }
        // Lyrics load with every song, so Now Playing knows up front whether there are any.
        .onChange(of: player.current?.id) { wallpaper.songChanged(cover: player.current?.artwork) }
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
                case .savedAlbums: SavedAlbumsView()
                case .liked: PageView(id: Library.likedID)
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
        case .savedAlbums: "Saved Albums"
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


