import AVFoundation
import SwiftUI
import WebKit

@main
struct TideApp: App {
    @State private var library = Library()
    @State private var remote = Remote()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        URLCache.shared = URLCache(memoryCapacity: 8 << 20, diskCapacity: 100 << 20)
    }

    var body: some Scene {
        WindowGroup {
            Root()
                .environment(library)
                .environment(remote)
                .task { await library.start() }
                .onChange(of: scenePhase, initial: true) {
                    if scenePhase == .active { remote.start() }
                }
        }
    }
}

struct Root: View {
    @Environment(Library.self) private var library
    @Environment(Remote.self) private var remote
    @State private var showPlayer = false

    var body: some View {
        Group {
            switch library.state {
            case .starting:
                ProgressView()
            case .signedOut:
                SignInScreen()
            default:
                TabView {
                    Tab("Home", systemImage: "house") { HomeTab() }
                    Tab("Library", systemImage: "music.note.list") { LibraryTab() }
                    Tab(role: .search) { SearchTab() }
                }
                .tabViewBottomAccessory { MiniPlayer { showPlayer = true } }
                .sheet(isPresented: $showPlayer) { NowPlayingScreen() }
            }
        }
        // The embedded player's web view has to be in the window to play; it sits
        // under the app's background.
        .background {
            ZStack {
                EmbedHost(player: remote.local.embed).frame(width: 200, height: 200)
                Color(.systemBackground).ignoresSafeArea()
            }
            .allowsHitTesting(false)
        }
    }
}

struct MiniPlayer: View {
    @Environment(Remote.self) private var remote
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let song = remote.state.song {
                Cover(url: song.artwork, pixels: 120).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(remote.target == .mac ? "On \(remote.macName ?? "Mac")" : song.artist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { remote.send(.toggle) } label: {
                    Image(systemName: remote.state.playing ? "pause.fill" : "play.fill")
                }
                Button { remote.send(.next) } label: { Image(systemName: "forward.fill") }
            } else {
                Text("Not playing").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

struct SignInScreen: View {
    @Environment(Library.self) private var library
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Sign in to YouTube Music").font(.title2.bold())
            Text("Your Home, playlists, liked songs and albums load from your account.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Sign In with Google") { signingIn = true }.buttonStyle(.borderedProminent)
        }
        .padding(32)
        .sheet(isPresented: $signingIn) {
            NavigationStack {
                SignInWebView {
                    signingIn = false
                    Task { await library.start() }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign In").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { signingIn = false } }
            }
        }
    }
}

/// Google's own login page in a web view. The app only keeps the resulting cookies.
struct SignInWebView: UIViewRepresentable {
    let signedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(signedIn: signedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        // The desktop site: the mobile one sends you to the App Store.
        view.customUserAgent = YTClient.userAgent
        view.navigationDelegate = context.coordinator
        let url = "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F"
        view.load(URLRequest(url: URL(string: url)!))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let signedIn: () -> Void
        private var done = false

        init(signedIn: @escaping () -> Void) { self.signedIn = signedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, webView.url?.host == "music.youtube.com" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done,
                      cookies.contains(where: { $0.name == "SAPISID" && $0.domain.hasSuffix("youtube.com") }) else { return }
                self.done = true
                DispatchQueue.main.async { self.signedIn() }
            }
        }
    }
}
