import AppKit
import SwiftUI

/// Moving colour blobs standing in for a real music video (mpv would render here).
struct FakeVideo: View {
    let song: Song
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { c, size in
                c.fill(Path(CGRect(origin: .zero, size: size)),
                       with: .color(Color(hue: song.hue, saturation: 0.7, brightness: 0.25)))
                c.addFilter(.blur(radius: min(size.width, size.height) * 0.08))
                for i in 0..<6 {
                    let d = Double(i)
                    let x = size.width * (0.5 + 0.38 * sin(t * (0.21 + d * 0.05) + d * 1.7))
                    let y = size.height * (0.5 + 0.36 * cos(t * (0.17 + d * 0.04) + d * 2.3))
                    let r = min(size.width, size.height) * (0.22 + 0.06 * sin(t * 0.5 + d))
                    let hue = (song.hue + d * 0.07).truncatingRemainder(dividingBy: 1)
                    c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                           with: .color(Color(hue: hue, saturation: 0.75, brightness: 0.95).opacity(0.75)))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("SAMPLE VIDEO")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(8)
        }
    }
}

/// 16:9 video with the ambient glow behind it (Pear's ambient-mode).
struct AmbientVideo: View {
    @Environment(Player.self) private var player
    let song: Song

    var body: some View {
        ZStack {
            FakeVideo(song: song, playing: player.isPlaying)
                .scaleEffect(1.15)
                .blur(radius: 50)
                .opacity(0.65)
            FakeVideo(song: song, playing: player.isPlaying)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    @State private var quality = "Auto (1080p)"
    @State private var note: String?
    @FocusState private var focused: Bool

    private let qualities = ["Auto (1080p)", "1080p", "720p", "480p", "360p"]

    var body: some View {
        ZStack {
            Color.black
            if let s = player.current {
                FakeVideo(song: s, playing: player.isPlaying)
                    .scaleEffect(1.2)
                    .blur(radius: 90)
                    .opacity(0.45)
                FakeVideo(song: s, playing: player.isPlaying)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .onTapGesture(count: 2) { router.exitVideoFullscreen() }
                    .onTapGesture { player.toggle(); poke() }

                if showLyrics { lyricLine(s) }
                controls(s).opacity(controlsVisible ? 1 : 0)
            }
            if let note {
                Text(note)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(28)
                    .transition(.opacity)
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
            skipNonMusicIntro()
        }
        .onChange(of: player.current?.id) { skipNonMusicIntro() }
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
                        Picker("Quality", selection: $quality) {
                            ForEach(qualities, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Quality: \(quality)")
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
                Slider(value: Binding(get: { min(player.position, s.playDuration) }, set: { player.seek($0); poke() }),
                       in: 0...s.playDuration)
                    .controlSize(.small)
                Text(formatTime(s.playDuration)).frame(width: 44, alignment: .leading)
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
        player.seek(min(max(0, player.position + delta), s.playDuration))
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

    /// Stand-in for SponsorBlock's "non-music" segment skip at the start of a video.
    private func skipNonMusicIntro() {
        guard player.position < 6 else { return }
        player.seek(6)
        withAnimation { note = "Skipped non-music intro (SponsorBlock)" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { note = nil } }
    }
}
