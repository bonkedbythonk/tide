import SwiftUI
import WebKit

/// YouTube Music's own web player, signed in with your account (Premium plays
/// without ads), for when the Mac can't be reached. It runs music.youtube.com in a
/// hidden web view and drives it with JavaScript: nothing is extracted, the page
/// plays the song itself. The queue lives in the page too, so it moves to the next
/// song without the app's help.
final class WebPlayer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Report {
        var time: TimeInterval
        var duration: TimeInterval
        var paused: Bool
        /// Index into the queue last given to `load`.
        var index: Int
    }

    var onReport: ((Report) -> Void)?
    let webView: WKWebView
    private var pending: (ids: [String], index: Int, start: TimeInterval)?
    private var pageReady = false

    override init() {
        let config = WKWebViewConfiguration()
        // The sign-in's cookies.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        // The desktop site; the mobile one sends you to the App Store.
        webView.customUserAgent = YTClient.userAgent
        #if DEBUG
        // Safari's Develop menu can attach to it, to see what the page is doing.
        webView.isInspectable = true
        #endif
        super.init()
        config.userContentController.add(self, name: "tide")
        webView.navigationDelegate = self
    }

    /// Plays `ids[index]` from `start`, then the rest of `ids` in order.
    func load(_ ids: [String], index: Int, at start: TimeInterval) {
        guard ids.indices.contains(index) else { return }
        pending = (ids, index, start)
        if pageReady {
            sendPending()
        } else if webView.url == nil {
            // The first song opens the page; the queue is handed over once it's up.
            webView.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(ids[index])")!))
        }
    }

    func play() { run("tide.video() && tide.video().play()") }
    func pause() { run("tide.video() && tide.video().pause()") }
    func stop() { pending = nil; run("window.tide && tide.video() && tide.video().pause()") }
    func seek(_ t: TimeInterval) { run("tide.video() && (tide.video().currentTime = \(t))") }
    func setVolume(_ v: Double) { run("tide.video() && (tide.video().volume = \(v))") }

    private func run(_ js: String) { webView.evaluateJavaScript(js) }

    private func sendPending() {
        guard let p = pending,
              let ids = try? JSONSerialization.data(withJSONObject: p.ids) else { return }
        pending = nil
        run("tide.start(\(String(decoding: ids, as: UTF8.self)), \(p.index), \(p.start))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any] else { return }
        if m["ready"] as? Bool == true {
            pageReady = true
            sendPending()
            return
        }
        onReport?(Report(time: m["t"] as? Double ?? 0, duration: m["d"] as? Double ?? 0,
                         paused: m["paused"] as? Bool ?? true, index: m["index"] as? Int ?? 0))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageReady = false
    }

    /// Runs in music.youtube.com. `#movie_player` is YouTube's player, with its
    /// usual JavaScript API; the page's own autoplay is overruled by our queue.
    private static let script = """
    (function () {
      if (window.tide) return;
      const post = m => webkit.messageHandlers.tide.postMessage(m);
      window.tide = {
        queue: [], index: 0, since: 0,
        player: () => document.querySelector('#movie_player'),
        video: () => document.querySelector('video'),
        start(ids, index, t) { this.queue = ids; this.play(index, t) },
        play(index, t) {
          this.index = index; this.since = Date.now();
          const p = this.player();
          if (p && p.loadVideoById) p.loadVideoById({ videoId: this.queue[index], startSeconds: t || 0 });
        },
        current() { const p = this.player(); return p && p.getVideoData ? p.getVideoData().video_id : null },
      };
      document.addEventListener('ended', e => {
        if (e.target.tagName === 'VIDEO' && tide.index + 1 < tide.queue.length) tide.play(tide.index + 1, 0);
      }, true);
      const ready = setInterval(() => {
        const p = tide.player();
        if (p && p.loadVideoById) { clearInterval(ready); post({ ready: true }) }
      }, 300);
      setInterval(() => {
        const v = tide.video(); if (!v) return;
        // The page's autoplay or a click moved on to something not in our queue: back to ours.
        const id = tide.current();
        if (tide.queue.length && id && id !== tide.queue[tide.index] && Date.now() - tide.since > 4000) {
          tide.play(Math.min(tide.index + 1, tide.queue.length - 1), 0);
        }
        post({ t: v.currentTime, d: v.duration || 0, paused: v.paused, index: tide.index });
      }, 1000);
    })();
    """
}

/// Keeps the web player in the window (it must be, to play), out of sight.
struct WebPlayerHost: UIViewRepresentable {
    let player: WebPlayer
    func makeUIView(context: Context) -> WKWebView {
        // Nearly invisible rather than hidden: a hidden web view stops playing.
        player.webView.isOpaque = false
        player.webView.alpha = 0.01
        return player.webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
