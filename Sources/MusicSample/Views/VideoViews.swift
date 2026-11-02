import AppKit
import SwiftUI

enum VideoHost { case fullscreen, nowPlaying, mini }

/// Shows mpv's video layer. There is one layer for the whole app, so exactly one
/// place owns it at a time: fullscreen, else Now Playing, else the mini player.
/// Places that appear and disappear together (Now Playing closing while the mini
/// player opens) used to both grab it, and the one being removed could win and take
/// the picture with it: black video.
struct VideoSurface: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    let role: VideoHost

    private var owner: VideoHost? {
        guard player.videoMode else { return nil }
        if router.videoFullscreen { return .fullscreen }
        if router.showNowPlaying { return .nowPlaying }
        return router.miniPlayerHidden ? nil : .mini
    }

    var body: some View {
        VideoHostView(video: player.engine.videoView, owns: owner == role)
    }
}

private struct VideoHostView: NSViewRepresentable {
    let video: MpvMetalView
    let owns: Bool

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard owns, video.superview !== host else { return }
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
            VideoSurface(role: .nowPlaying)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if player.isLoading || player.videoLoading { ProgressView().controlSize(.large) }
        }
        .frame(width: size.width, height: size.height)
        .animation(.snappy, value: player.videoAspect)
    }

    /// A wide video gets the 520 pt stage; a square or tall picture (often just the
    /// cover of an album track) stays the size of the normal artwork.
    private var size: CGSize {
        let aspect = player.videoAspect
        if aspect < 1.2 { return CGSize(width: 340 * min(aspect, 1), height: 340 / max(aspect, 1)) }
        let clamped = min(aspect, 2.4)
        return CGSize(width: 520, height: 520 / clamped)
    }
}

struct VideoFullscreenView: View {
    @Environment(Player.self) private var player
    @Environment(LyricsStore.self) private var lyrics
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
                VideoSurface(role: .fullscreen)
                // The video layer is AppKit; clicks are caught by this layer above it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { router.exitVideoFullscreen() }
                    .onTapGesture { player.toggle(); poke() }
                if player.isLoading || player.videoLoading { ProgressView().controlSize(.large) }

                if showLyrics {
                    lyricLine(s).task(id: s.id) { await lyrics.load(s, duration: player.duration) }
                }
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
        var line = ""
        if case .synced(let lines) = lyrics.result(for: s.id) {
            line = lines.last { $0.time <= player.position + 0.25 }?.text ?? ""
        }
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

/// Floating video in the corner of the window while a music video plays and
/// Now Playing is closed. Click to open Now Playing, double-click for fullscreen.
struct VideoMiniPlayer: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @State private var hovering = false

    var body: some View {
        ZStack {
            VideoSurface(role: .mini)
            if player.isLoading || player.videoLoading { ProgressView() }
            // Clicks land on this layer; the video itself is AppKit.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { router.enterVideoFullscreen() }
                .onTapGesture { withAnimation(.spring(duration: 0.45, bounce: 0.12)) { router.showNowPlaying = true } }
            if hovering {
                VStack {
                    HStack {
                        Button { withAnimation(.snappy) { router.miniPlayerHidden = true } } label: {
                            Image(systemName: "xmark")
                        }
                        .help("Hide the mini player")
                        Spacer()
                        Button { router.enterVideoFullscreen() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .help("Fullscreen")
                    }
                    Spacer()
                    Button(action: player.toggle) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Spacer()
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(10)
                .background(.black.opacity(0.35))
                .transition(.opacity)
            }
        }
        .frame(width: 320, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
