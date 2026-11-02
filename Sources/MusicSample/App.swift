import AppKit
import SwiftUI

@main
struct MusicSampleApp: App {
    @State private var library = Library()
    @State private var player = Player()
    @State private var router = Router()
    @State private var home = HomeConfig()
    @State private var lyrics = LyricsStore()

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
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("Playback") {
                // Space is handled by SpaceToPlay, so typing a space in a text field still works.
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
            CommandGroup(after: .sidebar) {
                Button("Back") { router.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button("Forward") { router.goForward() }.keyboardShortcut("]", modifiers: .command)
            }
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(Router.self) private var router
    @State private var swipe = SwipeTracker()

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            } detail: {
                ZStack {
                    DetailView()
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
            .toolbar(router.videoFullscreen ? .hidden : .automatic, for: .windowToolbar)
            Divider()
            PlayerBar()
        }
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
        .onAppear {
            swipe.install(router: router, player: player)
            SpaceToPlay.install(player: player)
        }
        .task { await library.start() }
        // Warms the yt-dlp worker on something you're likely to play anyway.
        .onChange(of: library.home.first?.songs.first?.id, initial: true) {
            if let song = library.home.first?.songs.first { player.prefetch(song) }
        }
        // Lyrics load with every song, so Now Playing knows up front whether there are any.
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
