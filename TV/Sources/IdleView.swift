import SwiftUI
import UIKit

/// Looks after an OLED screen: after a few minutes without the remote, with a song
/// loaded, Tide switches to IdleView. Moving focus or a new song counts as activity.
@MainActor @Observable final class IdleWatch {
    var idle = false
    @ObservationIgnored private var last = Date()
    @ObservationIgnored private var timer: Timer?
    /// Three minutes; `-idleAfter <seconds>` at launch shortens it for testing.
    static let after: TimeInterval = UserDefaults.standard.double(forKey: "idleAfter") > 0
        ? UserDefaults.standard.double(forKey: "idleAfter") : 3 * 60

    init() {
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.touch() }
        }
    }

    func start(_ player: TVPlayer) {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self, let player, !self.idle else { return }
                // A video keeps moving by itself; nothing loaded means nothing to show.
                if player.current != nil, !player.showsVideo, Date().timeIntervalSince(self.last) > Self.after {
                    self.idle = true
                }
            }
        }
    }

    func touch() { last = Date() }

    func wake() {
        idle = false
        touch()
    }
}

/// Dark and dim, and always moving: the cover, title and current lyric drift slowly to
/// a new place every 20 seconds, so nothing stays on the same pixels. Any press wakes.
struct IdleView: View {
    @Environment(TVPlayer.self) private var player
    @Environment(MacLink.self) private var link
    @Environment(IdleWatch.self) private var watch
    @State private var spot = CGPoint(x: 0.5, y: 0.5)
    @State private var lyrics: TVProtocol.Lyrics?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let song = player.current {
                    VStack(spacing: 22) {
                        Cover(hue: song.hue, url: song.artwork, side: 300, radius: 18)
                        Text(song.title).font(.system(size: 36, weight: .bold)).lineLimit(1)
                        Text(song.artist).font(.system(size: 26)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        if let line = currentLine {
                            Text(line).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                    .frame(width: 700)
                    .opacity(0.55)
                    .position(x: geo.size.width * spot.x, y: geo.size.height * spot.y)
                    .task(id: song.id) {
                        lyrics = try? await link.get("lyrics/" + song.id)
                    }
                }
                WakeCatcher { watch.wake() }.ignoresSafeArea()
            }
        }
        .task {
            // Glide to a new spot, staying clear of the edges, for as long as this shows.
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 20)) {
                    spot = CGPoint(x: .random(in: 0.3...0.7), y: .random(in: 0.35...0.65))
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private var currentLine: String? {
        guard let lines = lyrics?.lines, let i = lines.lastIndex(where: { $0.time <= player.time + 0.3 }) else { return nil }
        return lines[i].text.isEmpty ? nil : lines[i].text
    }
}

/// Takes every press and touch while the idle view shows, so the first one only wakes
/// (and Back doesn't also leave the app).
struct WakeCatcher: UIViewRepresentable {
    let wake: () -> Void

    final class Catcher: UIView {
        var wake: () -> Void = {}
        override var canBecomeFocused: Bool { true }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { wake() }
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { wake() }
    }

    func makeUIView(context: Context) -> Catcher { Catcher() }
    func updateUIView(_ view: Catcher, context: Context) { view.wake = wake }
}
