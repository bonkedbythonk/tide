import AppKit
import SwiftUI

/// Shows mpv's video layer. There is one layer for the whole app, so the
/// surface that is `active` takes it (Now Playing, or fullscreen on top).
struct VideoSurface: NSViewRepresentable {
    @Environment(Player.self) private var player
    var active = true

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        let video = player.engine.videoView
        guard active, video.superview !== host else { return }
        video.removeFromSuperview()
        video.frame = host.bounds
        video.autoresizingMask = [.width, .height]
        host.addSubview(video)
    }
}

/// 16:9 video with a glow from the cover art behind it (Pear's ambient-mode).
struct AmbientVideo: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    let song: Song

    var body: some View {
        ZStack {
            if let url = song.artwork {
                CachedImage(url: url, maxPixelSize: 200)
                    .scaleEffect(1.15)
                    .blur(radius: 50)
                    .opacity(0.7)
            }
            VideoSurface(active: !router.videoFullscreen)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if player.isLoading { ProgressView().controlSize(.large) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}

struct VideoFullscreenView: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showLyrics = false
    @FocusState private var focused: Bool

    private let qualities = [2160, 1440, 1080, 720, 480, 360]

    var body: some View {
        ZStack {
            Color.black
            if let s = player.current {
                VideoSurface()
                // The video layer is AppKit; clicks are caught by this layer above it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { router.exitVideoFullscreen() }
                    .onTapGesture { player.toggle(); poke() }
                if player.isLoading { ProgressView().controlSize(.large) }

                if showLyrics { lyricLine(s) }
                controls(s).opacity(controlsVisible ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onContinuousHover { _ in poke() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { seek(-5); return .handled }
        .onKeyPress(.rightArrow) { seek(5); return .handled }
        .onKeyPress(.escape) { router.exitVideoFullscreen(); return .handled }
        .onKeyPress("c") { showLyrics.toggle(); return .handled }
        .onAppear {
            focused = true
            poke()
        }
        .onDisappear { hideTask?.cancel() }
    }

    private func controls(_ s: Song) -> some View {
        VStack(spacing: 10) {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.title2.bold())
                    Text(s.artist).font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 18) {
                    LikeButton(songID: s.id)
                    StandaloneAddButton(songIDs: [s.id])
                    Button { showLyrics.toggle() } label: {
                        Image(systemName: showLyrics ? "captions.bubble.fill" : "captions.bubble")
                    }
                    .help("Lyrics overlay (C)")
                    Menu {
                        Picker("Max quality", selection: Binding(get: { player.videoQuality }, set: { player.videoQuality = $0 })) {
                            ForEach(qualities, id: \.self) { Text("\($0)p").tag($0) }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Max quality: \(player.videoQuality)p")
                    Button {
                        player.videoMode = false
                        router.exitVideoFullscreen()
                    } label: {
                        Image(systemName: "music.note")
                    }
                    .help("Switch to song (audio only)")
                    Button { router.exitVideoFullscreen() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Exit fullscreen (Esc)")
                }
                .font(.title3)
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Text(formatTime(player.position)).frame(width: 44, alignment: .trailing)
                Slider(value: Binding(get: { min(player.position, max(player.length, 1)) }, set: { player.seek($0); poke() }),
                       in: 0...max(player.length, 1))
                    .controlSize(.small)
                Text(formatTime(max(player.length, 1))).frame(width: 44, alignment: .leading)
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            HStack(spacing: 34) {
                Button(action: player.previous) { Image(systemName: "backward.fill") }
                Button { seek(-5) } label: { Image(systemName: "gobackward.5") }
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40)
                }
                Button { seek(5) } label: { Image(systemName: "goforward.5") }
                Button(action: player.next) { Image(systemName: "forward.fill") }
            }
            .font(.title2)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 30)
        .padding(.top, 120)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .frame(height: 300)
        }
        .foregroundStyle(.white)
    }

    private func lyricLine(_ s: Song) -> some View {
        let lines = FakeLyrics.lines(for: s)
        let line = lines.last { $0.time <= player.position }?.text ?? ""
        return Text(line)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 6)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(.black.opacity(line.isEmpty ? 0 : 0.35), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, controlsVisible ? 200 : 60)
            .animation(.easeOut(duration: 0.3), value: controlsVisible)
            .id(line)
            .transition(.opacity)
    }

    private func seek(_ delta: TimeInterval) {
        guard let s = player.current else { return }
        player.seek(min(max(0, player.position + delta), max(player.length, 1)))
        poke()
    }

    /// Show controls and cursor, then hide both after a few idle seconds (your fullscreen-auto-hide).
    private func poke() {
        if !controlsVisible { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true } }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.5)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
