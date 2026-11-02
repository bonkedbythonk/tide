import SwiftUI
import WebKit

/// YouTube's own embedded player, for when the Mac can't be reached. It only
/// plays while Tide is open, and some songs aren't allowed outside YouTube.
/// The player is kept small, which makes YouTube pick its lowest video quality,
/// so it uses about as much data as an audio stream.
final class EmbedPlayer: NSObject, WKScriptMessageHandler {
    var onTime: ((TimeInterval) -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((Int) -> Void)?
    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        super.init()
        config.userContentController.add(self, name: "yt")
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://tide.local/"))
    }

    func load(_ id: String, at start: TimeInterval) { run("load('\(id)', \(Int(start)))") }
    func play() { run("player.playVideo()") }
    func pause() { run("player.pauseVideo()") }
    func stop() { run("player && player.stopVideo && player.stopVideo()") }
    func seek(_ t: TimeInterval) { run("player.seekTo(\(t), true)") }
    func setVolume(_ v: Double) { run("player.setVolume(\(Int(v * 100)))") }

    private func run(_ js: String) { webView.evaluateJavaScript(js) }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let event = m["e"] as? String else { return }
        switch event {
        case "time": onTime?(m["t"] as? Double ?? 0)
        case "state": if m["s"] as? Int == 0 { onEnded?() }
        case "error": onError?(m["c"] as? Int ?? 0)
        default: break
        }
    }

    private static let page = """
    <!doctype html><meta name="viewport" content="width=device-width"><body style="margin:0;background:#000">
    <div id="p"></div>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
    var player, pending;
    function post(m) { webkit.messageHandlers.yt.postMessage(m) }
    function onYouTubeIframeAPIReady() {
      player = new YT.Player('p', { width: 200, height: 200,
        playerVars: { playsinline: 1, controls: 0, autoplay: 1 },
        events: {
          onReady: function () { if (pending) { load(pending[0], pending[1]); pending = null } },
          onStateChange: function (s) { post({ e: 'state', s: s.data }) },
          onError: function (x) { post({ e: 'error', c: x.data }) } } })
    }
    function load(id, t) {
      if (!player || !player.loadVideoById) { pending = [id, t]; return }
      player.loadVideoById({ videoId: id, startSeconds: t })
    }
    setInterval(function () {
      if (player && player.getCurrentTime) post({ e: 'time', t: player.getCurrentTime() })
    }, 1000)
    </script>
    """
}

/// Keeps the embedded player's web view in the window (it must be, to play),
/// out of sight.
struct EmbedHost: UIViewRepresentable {
    let player: EmbedPlayer
    func makeUIView(context: Context) -> WKWebView {
        // Nearly invisible rather than hidden: a hidden web view stops playing.
        player.webView.isOpaque = false
        player.webView.alpha = 0.01
        return player.webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
