import SwiftUI

/// The song playing, laid out like the Mac's Now Playing: cover, title and controls
/// on the left; lyrics or Up Next in a frosted panel on the right.
struct NowPlayingView: View {
    @Environment(TVPlayer.self) private var player
    @Environment(MacLink.self) private var link
    @State private var lyrics: TVProtocol.Lyrics?
    @State private var showQueue = false
    /// While the progress bar is selected, left and right seek instead of moving to the panel.
    @State private var scrubbing = false
    @State private var fullScreen = false
    /// Coming into the panel from the left lands on its Lyrics / Up Next switch, not on
    /// whichever queue row happens to sit level with the button you came from.
    @FocusState private var panelFocus: PanelFocus?

    var body: some View {
        if let song = player.current {
            HStack(spacing: 90) {
                VStack(spacing: 30) {
                    if player.showsVideo {
                        // Select makes it full screen.
                        Button { fullScreen = true } label: {
                            // Lets go of the player while full screen is open: tvOS shows a player's
                            // picture in only one layer, and after a mix this card could take it.
                            PlayerSurface(player: fullScreen ? nil : player.visiblePlayer)
                                .frame(width: 600, height: 338)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .buttonStyle(CardStyle())
                        .contextMenu { radioMenu }
                    } else {
                        // Selectable only for its menu: hold Select for Start Radio.
                        Button {} label: {
                            Cover(hue: song.hue, url: song.artwork, side: song.hasVideo ? 470 : 540, radius: 24)
                        }
                        .buttonStyle(CardStyle())
                        .contextMenu { radioMenu }
                    }
                    if song.hasVideo {
                        HStack(spacing: 16) {
                            Button("Song") { player.setVideo(false) }.buttonStyle(TabPillStyle(selected: !player.videoMode))
                            Button("Video") { player.setVideo(true) }.buttonStyle(TabPillStyle(selected: player.videoMode))
                        }
                    }
                    VStack(spacing: 8) {
                        Text(song.title).font(.system(size: 44, weight: .bold)).lineLimit(1)
                        Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 28)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Progress(time: player.time, duration: player.duration, focused: $scrubbing)
                    HStack(spacing: 40) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                            .buttonStyle(ControlStyle())
                        Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                            .buttonStyle(ControlStyle(main: true))
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                            .buttonStyle(ControlStyle())
                    }
                    if let error = player.error {
                        Text(error).font(.system(size: 22)).foregroundStyle(.red.opacity(0.9))
                    }
                }
                .frame(width: 600)

                Panel {
                    VStack(spacing: 10) {
                        HStack(spacing: 16) {
                            Button("Lyrics") { showQueue = false }.buttonStyle(TabPillStyle(selected: !showQueue))
                                .focused($panelFocus, equals: .lyrics)
                            Button("Up Next") { showQueue = true }.buttonStyle(TabPillStyle(selected: showQueue))
                                .focused($panelFocus, equals: .queue)
                        }
                        .padding(.top, 30)
                        side
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .disabled(scrubbing)
                    // One area for the focus engine: right from anywhere on the left gets in,
                    // even when nothing in the panel sits level with where you are.
                    .focusSection()
                    .onChange(of: panelFocus) { old, new in
                        if new == .row, old == nil { panelFocus = showQueue ? .queue : .lyrics }
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 20)
            .padding(.bottom, 50)
            .fullScreenCover(isPresented: $fullScreen) { FullScreenVideo() }
            // A song without a video leaves full screen.
            .onChange(of: player.showsVideo) { _, shows in if !shows { fullScreen = false } }
            .task(id: song.id) {
                lyrics = nil
                showQueue = false
                let found: TVProtocol.Lyrics? = try? await link.get("lyrics/" + song.id)
                lyrics = found ?? TVProtocol.Lyrics()
                // Nothing to read: show what's coming instead.
                if lyrics?.lines?.isEmpty != false, lyrics?.plain == nil { showQueue = true }
            }
        }
    }

    @ViewBuilder private var radioMenu: some View {
        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadioFromCurrent() }
    }

    @ViewBuilder private var side: some View {
        if showQueue {
            UpNext(focus: $panelFocus)
        } else if let lines = lyrics?.lines, !lines.isEmpty {
            SyncedLyrics(lines: lines, time: player.time)
        } else if let plain = lyrics?.plain {
            ScrollView {
                Text(plain).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(50)
            }
        } else {
            Text(lyrics == nil ? "Loading lyrics..." : "No lyrics for this song")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The thin bar and times under the cover.
/// The bar and times under the cover. Focus it and press left or right on the remote
/// to jump 10 seconds (hold to keep going), as in the Apple TV's own players.
struct Progress: View {
    @Environment(TVPlayer.self) private var player
    let time: TimeInterval
    let duration: TimeInterval
    @Binding var focused: Bool

    var body: some View {
        ProgressBar(time: time, duration: duration, highlighted: focused)
            .overlay(ScrubControl(onFocus: { focused = $0 }, seek: { player.seek(by: $0) }))
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

/// The bar itself, also shown (not selectable) over a full-screen video.
struct ProgressBar: View {
    let time: TimeInterval
    let duration: TimeInterval
    var highlighted = false

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let x = geo.size.width * min(1, max(0, time / max(duration, 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(highlighted ? 0.3 : 0.2))
                    Capsule().fill(.white).frame(width: x)
                    if highlighted {
                        Circle().fill(.white).frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.4), radius: 8)
                            .offset(x: x - 13)
                    }
                }
                .frame(height: highlighted ? 14 : 8)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 26)
            HStack {
                Text(formatTime(time))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(highlighted ? 0.9 : 0.6)).monospacedDigit()
        }
    }
}

/// The Lyrics / Up Next switch at the top of the panel.
struct TabPillStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, selected: selected) }

    private struct Look: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .foregroundStyle(focused ? .black : selected ? .white : .white.opacity(0.6))
                .background(Capsule().fill(focused ? .white : selected ? .white.opacity(0.18) : .clear))
                .scaleEffect(focused ? 1.08 : 1)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

struct SyncedLyrics: View {
    let lines: [LyricLine]
    let time: TimeInterval

    var body: some View {
        let currentLine = lines.lastIndex { $0.time <= time + 0.3 } ?? -1
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 50, weight: .bold))
                            .foregroundStyle(i == currentLine ? .white : .white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 260)
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentLine) { _, line in
                withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(max(0, line), anchor: .center) }
            }
            .onAppear { proxy.scrollTo(max(0, currentLine), anchor: .center) }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

enum PanelFocus: Hashable { case lyrics, queue, row }

struct UpNext: View {
    @Environment(TVPlayer.self) private var player
    var focus: FocusState<PanelFocus?>.Binding

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(player.upNext.prefix(40).enumerated()), id: \.offset) { i, song in
                    Button { player.jump(to: player.index + 1 + i) } label: { SongRow(song: song, showsAlbum: false) }
                        .buttonStyle(RowStyle())
                        .songMenu(song)
                        .focused(focus, equals: .row)
                }
            }
            .padding(30)
        }
    }
}
