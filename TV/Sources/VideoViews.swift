import AVFoundation
import SwiftUI

/// Draws a player's picture, without the system's own controls (Tide's are its own).
struct PlayerSurface: UIViewRepresentable {
    /// nil leaves the surface black, so another surface can show this player's picture.
    let player: AVPlayer?

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        // A mix moves the picture to the other player.
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// The video filling the screen. Select shows the title and progress for a few seconds;
/// Back returns to Now Playing while it keeps playing.
struct FullScreenVideo: View {
    @Environment(TVPlayer.self) private var player
    @State private var showInfo = true
    @State private var hideToken = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: player.visiblePlayer).ignoresSafeArea()
            if showInfo, let song = player.current {
                VStack(alignment: .leading, spacing: 18) {
                    Text(song.title).font(.system(size: 44, weight: .bold)).lineLimit(1)
                    Text(song.artist).font(.system(size: 28)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    ProgressBar(time: player.time, duration: player.duration)
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea())
                .transition(.opacity)
            }
        }
        // Left and right seek (hold to keep going, or swipe), like the bar in Now Playing.
        .overlay(ScrubControl(seek: { player.seek(by: $0); reveal() },
                              onSelect: { reveal() },
                              onPlayPause: { player.toggle(); reveal() }).ignoresSafeArea())
        .onAppear { reveal() }
        .animation(.easeInOut(duration: 0.3), value: showInfo)
    }

    private func reveal() {
        showInfo = true
        hideToken += 1
        let token = hideToken
        Task {
            try? await Task.sleep(for: .seconds(4))
            if token == hideToken { showInfo = false }
        }
    }
}

/// The selectable part of the progress bar, in UIKit so it hears the remote itself: a
/// left or right press jumps 10 s, holding keeps jumping until released, and a swipe
/// on the touchpad scrubs. SwiftUI's move command reports a press only once and lets
/// the focus engine take the arrows first.
struct ScrubControl: UIViewRepresentable {
    var onFocus: (Bool) -> Void = { _ in }
    let seek: (Double) -> Void
    /// Select and play/pause, for when this fills the screen (full-screen video).
    var onSelect: (() -> Void)?
    var onPlayPause: (() -> Void)?

    final class Control: UIView {
        var onFocus: (Bool) -> Void = { _ in }
        var seek: (Double) -> Void = { _ in }
        var onSelect: (() -> Void)?
        var onPlayPause: (() -> Void)?
        private var repeatTimer: Timer?
        private var panned: CGFloat = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            addGestureRecognizer(pan)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var canBecomeFocused: Bool { true }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus(isFocused)
            if !isFocused { stopRepeating() }
        }

        private func direction(_ presses: Set<UIPress>) -> Double? {
            switch presses.first?.type {
            case .leftArrow: -1
            case .rightArrow: 1
            default: nil
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if presses.first?.type == .select, let onSelect { return onSelect() }
            if presses.first?.type == .playPause, let onPlayPause { return onPlayPause() }
            guard let step = direction(presses) else { return super.pressesBegan(presses, with: event) }
            seek(step * 10)
            stopRepeating()
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in self?.seek(step * 10) }
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard direction(presses) != nil else { return super.pressesEnded(presses, with: event) }
            stopRepeating()
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard direction(presses) != nil else { return super.pressesCancelled(presses, with: event) }
            stopRepeating()
        }

        private func stopRepeating() {
            repeatTimer?.invalidate()
            repeatTimer = nil
        }

        /// A swipe across the touchpad: 10 s for every 120 points of travel.
        @objc private func swiped(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began: panned = 0
            case .changed:
                let x = pan.translation(in: self).x
                while x - panned >= 120 { panned += 120; seek(10) }
                while x - panned <= -120 { panned -= 120; seek(-10) }
            default: break
            }
        }
    }

    func makeUIView(context: Context) -> Control { Control() }

    func updateUIView(_ view: Control, context: Context) {
        view.onFocus = onFocus
        view.seek = seek
        view.onSelect = onSelect
        view.onPlayPause = onPlayPause
    }
}
