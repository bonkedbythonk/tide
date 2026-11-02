import SwiftUI
import WebKit

struct SignedOutView: View {
    @Environment(Library.self) private var library
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Sign in to YouTube Music").font(.title.bold())
            Text("Your Home, playlists, liked songs and albums load from your account.")
                .foregroundStyle(.secondary)
            Button("Sign In with Google") { signingIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $signingIn) {
            SignInSheet {
                signingIn = false
                Task { await library.start() }
            }
        }
    }
}

/// Google's own login page in a web view. The app only keeps the resulting cookies.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    let signedIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to YouTube Music").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(12)
            Divider()
            SignInWebView(signedIn: signedIn)
        }
        .frame(width: 520, height: 700)
    }
}

struct SignInWebView: NSViewRepresentable {
    let signedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(signedIn: signedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = YTClient.userAgent
        view.navigationDelegate = context.coordinator
        let url = "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F"
        view.load(URLRequest(url: URL(string: url)!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

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
