import AppKit
import SwiftUI

struct PlayerBar: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            NowPlayingInfo().frame(width: 280, alignment: .leading)
            Spacer(minLength: 0)
            TransportControls().frame(minWidth: 320, maxWidth: 540)
                // The whole middle of the bar, buttons included: a sideways swipe there seeks.
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { router.pointerOverProgress = $0 }
            Spacer(minLength: 0)
            PlayerExtras().frame(width: 320, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        // Over a wallpaper the panels' gap is already above the bar, so the same gap
        // goes below it and the controls sit midway.
        .padding(.bottom, wallpaper.isActive ? PanelStyle.margin : 0)
        .frame(height: wallpaper.isActive ? PanelStyle.barHeight : 76)
        // Scrolling up or down anywhere on the bar sets the volume.
        .contentShape(Rectangle())
        .onHover { router.pointerOverPlayerBar = $0 }
        // Over a wallpaper it sits on the window's dark frame, like Spotify's.
        .background { if !wallpaper.isActive { Rectangle().fill(.bar) } }
        .environment(\.colorScheme, wallpaper.isActive ? .dark : colorScheme)
        // Clicking anywhere on the bar that isn't a control opens or closes Now Playing.
        .contentShape(Rectangle())
        .onTapGesture {
            guard player.current != nil else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0)) { router.showNowPlaying.toggle() }
        }
    }
}

/// Current song. Two-finger swipe over it skips.
struct NowPlayingInfo: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            if let s = player.current {
                // During a smart transition the old song stays put while the new one's
                // cover comes in over it and the titles cross over.
                let mix = player.mix
                let shown = mix?.from ?? s
                HStack(spacing: 12) {
                    Group {
                        if let mix {
                            MixCover(mix: mix, to: s).id(mix.began)
                        } else {
                            Artwork(hue: s.hue, url: s.artwork, side: 52, radius: 6)
                        }
                    }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: router.showNowPlaying ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(3)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    if let mix {
                        MixTitles(mix: mix, to: s).id(mix.began)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(text: s.title).font(.headline)
                            if let error = player.lastError {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                            } else if player.isLoading {
                                Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                ArtistLink(song: s).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .id(shown.id)
                .transition(.push(from: player.skipForward ? .trailing : .leading))
                .contextMenu { SongMenu(songs: [s]) }
                .draggable(library.dragPayload([s])) { DragPreview(songs: [s]) }
                Spacer(minLength: 4)
                LikeButton(songID: s.id)
                StandaloneAddButton(songIDs: [s.id])
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)).frame(width: 52, height: 52)
                Text("Not playing").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.28), value: player.current?.id)
        .contentShape(Rectangle())
        .onHover { router.pointerOverPlayerSong = $0 }
    }
}

/// One line of text that, when it doesn't fit, slides over to show the rest, rests,
/// and slides back.
struct MarqueeText: View {
    let text: String
    @State private var width: CGFloat = 0
    @State private var full: CGFloat = 0
    @State private var slid = false

    var body: some View {
        let overflow = max(0, full - width)
        Text(text).lineLimit(1).hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .leading) {
                Text(text).lineLimit(1).fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { full = $0 }
                    .offset(x: slid ? -overflow : 0)
            }
            .clipped()
            .task(id: "\(text)\(overflow)") {
                slid = false
                guard overflow > 1 else { return }
                let seconds = Double(overflow) / 30
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: seconds)) { slid = true }
                    try? await Task.sleep(for: .seconds(seconds + 2.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: seconds)) { slid = false }
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
    }
}

/// Depth dissolve for a mix: the old cover eases back and softens while the new one
/// settles forward into focus, kept inside the cover's frame.
private struct MixCover: View {
    let mix: Player.Mix
    let to: Song
    @State private var on = false

    var body: some View {
        ZStack {
            Artwork(hue: mix.from.hue, url: mix.from.artwork, side: 52, radius: 6)
                .scaleEffect(on ? 1.08 : 1).blur(radius: on ? 3 : 0).opacity(on ? 0 : 1)
            Artwork(hue: to.hue, url: to.artwork, side: 52, radius: 6)
                .scaleEffect(on ? 1 : 1.08).blur(radius: on ? 0 : 3).opacity(on ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            let left = max(0.3, mix.seconds - Date().timeIntervalSince(mix.began))
            withAnimation(.easeInOut(duration: left)) { on = true }
        }
    }
}

/// One title at a time during a mix: the old one lifts away and blurs out, then the
/// new one rises into place.
private struct MixTitles: View {
    let mix: Player.Mix
    let to: Song
    @State private var out = false
    @State private var into = false

    var body: some View {
        ZStack(alignment: .leading) {
            title(mix.from).opacity(out ? 0 : 1).offset(y: out ? -6 : 0).blur(radius: out ? 4 : 0)
            title(to).opacity(into ? 1 : 0).offset(y: into ? 0 : 6).blur(radius: into ? 0 : 4)
        }
        .onAppear {
            let s = mix.seconds
            withAnimation(.easeInOut(duration: 0.45 * s)) { out = true }
            withAnimation(.easeInOut(duration: 0.5 * s).delay(0.5 * s)) { into = true }
        }
    }

    private func title(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MarqueeText(text: song.title).font(.headline)
            Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct TransportControls: View {
    @Environment(\.barAccent) private var accent
    @Environment(\.mixGlow) private var glow
    @Environment(Player.self) private var player

    var body: some View {
        // Songs from Home arrive without a length; show none until mpv knows it.
        let known = player.length > 0
        let duration = known ? player.length : 1
        let shown = player.scrubPosition ?? player.position
        VStack(spacing: 4) {
            HStack(spacing: 24) {
                Button { withAnimation(.snappy(duration: 0.45)) { player.shuffle.toggle() } } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.shuffle ? accent : Color.secondary)
                }
                .help("Shuffle")
                Button(action: player.previous) { Image(systemName: "backward.fill").font(.title3) }
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .contentTransition(.symbolEffect(.replace))
                }
                Button(action: player.next) { Image(systemName: "forward.fill").font(.title3) }
                Button(action: player.cycleRepeat) {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : accent)
                }
                .help("Repeat")
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(known ? formatTime(shown) : "–:––").frame(width: 40, alignment: .trailing)
                TimelineView(.animation(paused: !player.isPlaying && player.mix == nil)) { context in
                    let now = player.scrubPosition ?? player.position(at: context.date)
                    CometBar(value: known ? min(now, duration) : 0, duration: duration,
                             glow: glow, intensity: player.mix?.swell(at: context.date) ?? 0,
                             mixAt: player.upcomingMix.map { $0 / duration },
                             enabled: known, seek: player.seek)
                }
                Text(known ? formatTime(duration) : "–:––").frame(width: 40, alignment: .leading)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

/// The progress bar: a thin track with a white head. A small mark shows where the
/// next song will mix in; during the mix the head glows and trails light in the new
/// song's colour. Click or drag anywhere on it to seek; the seek happens on release.
struct CometBar: View {
    let value: TimeInterval
    let duration: TimeInterval
    let glow: Color
    /// How brightly it glows, 0 outside a mix.
    let intensity: Double
    /// Where the next song mixes in, as a fraction of the song.
    let mixAt: Double?
    let enabled: Bool
    let seek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = dragging ?? min(1, max(0, value / max(duration, 1)))
            let x = width * fraction
            let big = hovering || dragging != nil
            let color = glow
            let on = intensity
            // Drawn rather than laid out: views snap to whole pixels, which makes a slow
            // bar tick; a canvas draws it at the exact fraction.
            // The canvas reaches past the bar so the head and glow aren't cut off at the ends.
            Canvas { ctx, size in
                ctx.translateBy(x: 24, y: 0)
                let mid = size.height / 2
                func pill(_ from: CGFloat, _ to: CGFloat, _ height: CGFloat) -> Path {
                    Path(roundedRect: CGRect(x: from, y: mid - height / 2, width: max(0, to - from), height: height),
                         cornerRadius: height / 2)
                }
                let h = 3 + 2 * on
                ctx.fill(pill(0, width, h), with: .color(.white.opacity(0.18)))
                ctx.fill(pill(0, x, h), with: .color(.white.opacity(0.55)))
                if let mixAt {
                    let m = width * min(1, max(0, mixAt))
                    ctx.drawLayer { l in
                        l.addFilter(.shadow(color: glow.opacity(0.8), radius: 3))
                        l.fill(pill(m - 1, m + 1, 8), with: .color(glow))
                    }
                }
                if on > 0 {
                    ctx.drawLayer { l in
                        l.opacity = on
                        l.addFilter(.shadow(color: color, radius: 6))
                        l.addFilter(.shadow(color: color.opacity(0.7), radius: 14))
                        l.fill(pill(x - min(140, x), x, 5), with: .linearGradient(
                            Gradient(colors: [color.opacity(0), color.opacity(0.95)]),
                            startPoint: CGPoint(x: x - min(140, x), y: mid), endPoint: CGPoint(x: x, y: mid)))
                    }
                }
                let d = (big ? 11 : 9) + 3 * on
                ctx.drawLayer { l in
                    if on > 0 {
                        l.addFilter(.shadow(color: color.opacity(on), radius: 6))
                        l.addFilter(.shadow(color: color.opacity(0.8 * on), radius: 16))
                    }
                    l.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: mid - d / 2, width: d, height: d)), with: .color(.white))
                }
            }
            .padding(-24)
            .help(mixAt == nil ? "" : "The next song mixes in at the mark")
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in if enabled { dragging = min(1, max(0, g.location.x / width)) } }
                    .onEnded { _ in
                        if let d = dragging { seek(d * duration) }
                        dragging = nil
                    }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: 16)
        .opacity(enabled ? 1 : 0.5)
    }
}

struct PlayerExtras: View {
    @Environment(\.barAccent) private var accent
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 14) {
            Button { player.videoMode.toggle() } label: {
                Image(systemName: player.videoMode ? "play.rectangle.fill" : "play.rectangle")
                    .foregroundStyle(player.videoMode ? accent : Color.secondary)
            }
            .help(player.videoMode ? "Switch to song" : "Switch to music video")
            .disabled(player.current == nil)
            if player.videoMode {
                Button { router.enterVideoFullscreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.secondary)
                }
                .help("Fullscreen video")
            }
            panelButton("quote.bubble", tab: .lyrics, help: "Lyrics")
            panelButton("list.bullet", tab: .queue, help: "Up Next")
            Button { player.discordPresence.toggle() } label: {
                Image(nsImage: DiscordLogo.image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    // Measured against the symbols beside it: about 15 pt wide, 12 tall.
                    .frame(width: 15, height: 15)
                    .foregroundStyle(player.discordPresence ? Color.primary : Color.secondary)
            }
            .help(player.discordPresence ? "Showing what's playing on Discord" : "Not showing on Discord")
            PopoverButton(symbol: "slider.vertical.3", help: "Sound") { SoundPopover() }
            HStack(spacing: 6) {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: $player.volume).controlSize(.mini).frame(width: 80)
            }
        }
        .buttonStyle(.plain)
    }

    private func panelButton(_ symbol: String, tab: PanelTab, help: String) -> some View {
        let active = router.panelTab == tab && (router.showNowPlaying ? router.nowPlayingPanel : router.panelVisible)
        return Button {
            if router.showNowPlaying {
                withAnimation(.snappy) {
                    if router.nowPlayingPanel, router.panelTab == tab {
                        router.nowPlayingPanel = false
                    } else {
                        router.panelTab = tab
                        router.nowPlayingPanel = true
                    }
                }
            } else {
                router.togglePanel(tab)
            }
        } label: {
            Image(systemName: symbol).foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .help(help)
    }
}

struct PopoverButton<Content: View>: View {
    @Environment(\.barAccent) private var accent
    let symbol: String
    let help: String
    @ViewBuilder let content: Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: symbol).foregroundStyle(open ? accent : Color.secondary)
        }
        .help(help)
        .popover(isPresented: $open, arrowEdge: .top) { content }
    }
}

struct SoundPopover: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        Form {
            LabeledContent("Crossfade") {
                HStack {
                    Slider(value: $player.crossfade, in: 0...12, step: 1)
                    Text(player.crossfade == 0 ? "Off" : "\(Int(player.crossfade)) s")
                        .monospacedDigit().frame(width: 34, alignment: .trailing)
                }
            }
            .disabled(player.smartTransitions)
            .help(player.smartTransitions ? "Smart transitions choose the crossfade" : "")
            Toggle("Smart transitions", isOn: $player.smartTransitions)
                .help("Crossfade on the beat and skip quiet endings and intros (needs ffmpeg). Off for videos.")
            Toggle("Autoplay similar songs", isOn: $player.autoplay)
                .help("When the queue runs out, keep going with YouTube Music's radio for the last song")
            Toggle("Gapless playback", isOn: $player.gapless)
                .disabled(player.smartTransitions || player.crossfade > 0)
                .help("Start the next song the moment this one ends (when there's no crossfade)")
            Toggle("Match YouTube Music loudness", isOn: $player.matchLoudness)
            Toggle("Smooth transitions", isOn: $player.smoothTransitions)
                .help("Fade the volume on pause, resume and skip")
            Picker("Equalizer", selection: $player.eq) {
                ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Sleep timer", selection: $player.sleepTimer) {
                ForEach(SleepTimer.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 360)
    }
}

struct SidePanelView: View {
    @Environment(Router.self) private var router
    @Environment(WallpaperStore.self) private var wallpaper

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            PillSwitch(options: [("Up Next", PanelTab.queue), ("Lyrics", PanelTab.lyrics), ("Comments", PanelTab.comments)],
                       selection: $router.panelTab)
                .padding(12)
            switch router.panelTab {
            case .queue: QueueView()
            case .lyrics: LyricsView(fontSize: 20)
            case .comments: CommentsView()
            }
        }
        // Over a wallpaper: inside the main panel, the window's wallpaper a touch darker.
        .background { if wallpaper.isActive { Color.black.opacity(0.2).ignoresSafeArea() } }
    }
}

struct QueueView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            MoodField().padding(.horizontal, 12).padding(.bottom, 8)
            queueList
        }
    }

    /// Styled like Now Playing's Up Next (plain rows, hover highlight, no section
    /// bars); still a List, which gives drag to reorder and swipe to remove.
    private var queueList: some View {
        List {
            if let s = player.current {
                header { Text("Now Playing") }
                QueueRow(song: s, current: true)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.12)))
                    .queueRowStyle()
            }
            header {
                Text("Up Next")
                Spacer()
                UpNextActions()
            }
            .padding(.top, 12)
            if player.upNext.isEmpty {
                Text("Drop songs here to queue them").foregroundStyle(.secondary).padding(8).queueRowStyle()
            }
            ForEach(QueueEntry.list(player.upNext)) { entry in
                let i = entry.index, s = entry.song
                QueueRow(song: s, current: false)
                    .padding(8)
                    .contentShape(Rectangle())
                    .modifier(HoverHighlight())
                    .onTapGesture { player.jump(to: player.index + 1 + i) }
                    .contextMenu { SongMenu(songs: [s], upNextIndex: i) }
                    .queueRowStyle()
            }
            .onMove { player.moveUpNext(from: $0, to: $1) }
            .onDelete { player.removeUpNext(at: $0) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .dropDestination(for: String.self) { items, _ in
            let songs = library.songs(SongDrag.ids(from: items))
            guard !songs.isEmpty else { return false }
            player.addToQueue(songs)
            library.showToast(songs.count == 1 ? "Added to queue" : "Added \(songs.count) songs to queue")
            return true
        }
    }

    private func header<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .queueRowStyle()
    }
}

private extension View {
    /// A side panel queue row: no list background, separators or default insets.
    func queueRowStyle() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
    }
}

/// Describe what you want to hear; Up Next is replaced with it and keeps going.
struct MoodField: View {
    @Environment(Player.self) private var player
    var placeholder = "Describe a mood, like \"trance classics\""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        player.startMood(text)
                        text = ""
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            if let pending = player.moodLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Finding songs for \"\(pending)\"...").lineLimit(1)
                    Button { player.endMood() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Cancel")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let mood = player.mood {
                HStack(spacing: 4) {
                    Text("Mood: \(mood)").lineLimit(1)
                    Button { player.endMood() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop the mood; Up Next goes back to the radio")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: player.mood)
        .animation(.snappy, value: player.moodLoading)
    }
}

/// Save the queue as a playlist, or clear what's after the current song.
struct UpNextActions: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        if !player.upNext.isEmpty {
            HStack(spacing: 12) {
                Button("Save as Playlist") {
                    router.newPlaylist(library, with: (player.current.map { [$0] } ?? []) + player.upNext)
                }
                Button("Clear") { withAnimation(.snappy) { player.clearUpNext() } }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

struct QueueRow: View {
    let song: Song
    let current: Bool

    var body: some View {
        HStack(spacing: 10) {
            Artwork(hue: song.hue, url: song.artwork, side: 36, radius: 4, symbol: nil)
                .overlay { if current { PlayingIndicator() } }
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1).fontWeight(current ? .semibold : .regular)
                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(song.duration > 0 ? formatTime(song.duration) : "").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Synced lyrics: current line highlighted and kept centred; click a line to jump there.
struct LyricsView: View {
    @Environment(Player.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    var fontSize: CGFloat = 20

    var body: some View {
        if let song = player.current {
            Group {
                switch lyrics.result(for: song.id) {
                case .synced(let lines): synced(lines)
                case .plain(let text): plain(text)
                case .instrumental: message("Instrumental", "pianokeys")
                case .some(.none): message("No lyrics found for this song", "text.badge.xmark")
                case nil: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(song.id)
            .transition(.opacity)
            .task(id: song.id) {
                // Give mpv a moment to report the length; it picks the right LRCLIB version.
                for _ in 0..<15 where player.duration <= 0 { try? await Task.sleep(for: .milliseconds(200)) }
                await lyrics.load(song, duration: player.duration)
            }
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note")
        }
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        // A little ahead of the audio, so a line lights up as it's sung, not after.
        let currentIndex = lines.lastIndex { $0.time <= player.position + 0.25 } ?? -1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize * 0.75) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i].text)
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(i == currentIndex ? Color.primary : Color.secondary)
                            .opacity(i == currentIndex ? 1 : (i < currentIndex ? 0.4 : 0.7))
                            .scaleEffect(i == currentIndex ? 1.03 : 1, anchor: .leading)
                            .id(i)
                            .onTapGesture { player.seek(lines[i].time) }
                    }
                    Text("Lyrics from LRCLIB").font(.caption).foregroundStyle(.tertiary).padding(.top, 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 140)
                .animation(.easeOut(duration: 0.25), value: currentIndex)
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentIndex) { _, i in
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(max(i, 0), anchor: .center) }
            }
            .onAppear { proxy.scrollTo(max(currentIndex, 0), anchor: .center) }
        }
    }

    private func plain(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Not synced").font(.caption).foregroundStyle(.tertiary)
                Text(text).font(.system(size: fontSize * 0.8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func message(_ text: String, _ symbol: String) -> some View {
        ContentUnavailableView(text, systemImage: symbol)
    }
}

/// Soft blobs in the cover's colours drifting behind the artwork; they hold still
/// while paused. Core Animation runs the drift and the blur on the GPU, so nothing
/// is redrawn on the main thread each frame.
struct CoverLight: NSViewRepresentable {
    @Environment(Player.self) private var player
    @Environment(WallpaperStore.self) private var wallpaper

    func makeNSView(context: Context) -> CoverLightView { CoverLightView() }

    func updateNSView(_ view: CoverLightView, context: Context) {
        let colors = wallpaper.coverPalette.isEmpty ? [wallpaper.coverAccent ?? .accentColor] : wallpaper.coverPalette
        view.update(colors: colors.map { NSColor($0).cgColor }, playing: player.isPlaying)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CoverLightView, context: Context) -> CGSize? {
        CGSize(width: 820, height: 820)
    }
}

final class CoverLightView: NSView {
    private let blobs = (0..<3).map { _ in CALayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        for (i, blob) in blobs.enumerated() {
            let side = 560 - CGFloat(i) * 70
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            blob.opacity = i == 2 ? 0.6 : 0.8
            // A disc fading to clear at its edge: the softness is built in, so no blur
            // filter has to run while the blobs move.
            let mask = CAGradientLayer()
            mask.type = .radial
            mask.colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)]
            mask.locations = [0, 0.45, 1]
            mask.startPoint = CGPoint(x: 0.5, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 1)
            mask.frame = blob.bounds
            blob.mask = mask
            root.addSublayer(blob)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        // Each blob drifts around its own slow loop, centred on the artwork.
        for (i, blob) in blobs.enumerated() {
            let loop = CAKeyframeAnimation(keyPath: "position")
            // A small loop, so the light stays centred on the cover and only shifts.
            loop.path = CGPath(ellipseIn: CGRect(x: bounds.midX - 60, y: bounds.midY - 45, width: 120, height: 90),
                               transform: nil)
            loop.duration = 48 + Double(i) * 17
            // Spread evenly around their loops, so they don't bunch up on one side.
            loop.timeOffset = loop.duration * Double(i) / 3
            loop.repeatCount = .infinity
            loop.calculationMode = .paced
            blob.position = CGPoint(x: bounds.midX, y: bounds.midY)
            blob.add(loop, forKey: "drift")
        }
    }

    func update(colors: [CGColor], playing: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        for (i, blob) in blobs.enumerated() { blob.backgroundColor = colors[i % colors.count] }
        CATransaction.commit()
        guard let root = layer, (root.speed > 0) != playing else { return }
        // Pausing freezes the layer clock where it is; playing resumes from there.
        if playing {
            let paused = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            let now = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = now
        }
    }
}

struct NowPlayingView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(LyricsStore.self) private var lyrics
    @State private var appeared = false
    /// Set when Now Playing moved to Up Next because a song had no lyrics, so it
    /// can move back for the next song that has them.
    @State private var leftLyricsForMissing = false

    /// nil while still loading.
    private var hasLyrics: Bool? {
        guard let id = player.current?.id, let result = lyrics.result(for: id) else { return nil }
        switch result {
        case .synced, .plain: return true
        case .instrumental, .none: return false
        }
    }

    var body: some View {
        @Bindable var router = router
        ZStack(alignment: .topLeading) {
            if let s = player.current {
                if wallpaper.isActive {
                    // Now Playing is where the wallpaper shows sharp; darker toward the
                    // bottom and behind the lyrics so the text stays readable.
                    WallpaperBackground(sharp: true)
                        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom))
                        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .trailing))
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [Color(hue: s.hue, saturation: 0.6, brightness: 0.55), Color(hue: s.hue, saturation: 0.4, brightness: 0.15)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .overlay(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6), value: s.id)
                }

                HStack(alignment: .center, spacing: 48) {
                    VStack(spacing: 18) {
                        Group {
                            if player.videoMode {
                                AmbientVideo(song: s)
                                    .onTapGesture(count: 2) { router.enterVideoFullscreen() }
                                    .overlay(alignment: .bottomTrailing) {
                                        Button { router.enterVideoFullscreen() } label: {
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .padding(8)
                                                .background(.ultraThinMaterial, in: Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(10)
                                        .help("Fullscreen (or double-click the video)")
                                    }
                            } else {
                                Artwork(hue: s.hue, url: s.artwork, side: 340, radius: 14)
                                    .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                                    .animation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
                                    .onHover { router.pointerOverPlayerSong = $0 }
                            }
                        }
                        .id("\(s.id)-\(player.videoMode)")
                        .contextMenu { SongMenu(songs: [s]) }
                        .draggable(library.dragPayload([s])) { DragPreview(songs: [s]) }
                        .background { if !player.videoMode { CoverLight().frame(width: 820, height: 820) } }
                        .transition(.push(from: player.skipForward ? .trailing : .leading))
                        .scaleEffect(appeared ? 1 : 0.85)
                        .opacity(appeared ? 1 : 0)

                        PillSwitch(options: [("Song", false), ("Video", true)],
                                   selection: Binding(get: { player.videoMode }, set: { player.videoMode = $0 }))
                        VStack(spacing: 4) {
                            MarqueeText(text: s.title).font(.title.bold())
                            HStack(spacing: 0) {
                                ArtistLink(song: s)
                                if !s.album.isEmpty {
                                    Text(" — ")
                                    AlbumLink(song: s)
                                }
                            }
                            .font(.title3).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contextMenu { SongMenu(songs: [s]) }
                        .draggable(library.dragPayload([s])) { DragPreview(songs: [s]) }
                        .id(s.id)
                        .transition(.opacity)
                        HStack(spacing: 18) {
                            LikeButton(songID: s.id)
                            StandaloneAddButton(songIDs: [s.id])
                            RadioButton(song: s)
                        }
                        .font(.title2)
                    }
                    .frame(width: player.videoMode && player.videoAspect >= 1.2 ? 520 : 380)
                    .frame(maxHeight: .infinity)
                    .animation(.snappy(duration: 0.35), value: s.id)
                    .animation(.snappy(duration: 0.35), value: player.videoMode)

                    if router.nowPlayingPanel {
                    VStack(spacing: 8) {
                        PillSwitch(options: [("Lyrics", PanelTab.lyrics), ("Up Next", PanelTab.queue), ("Comments", PanelTab.comments)],
                                   selection: $router.panelTab)
                        Group {
                            switch router.panelTab {
                            case .lyrics: LyricsView(fontSize: 28)
                            case .queue: NowPlayingQueue()
                            case .comments: CommentsView()
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    .padding(wallpaper.isActive ? 14 : 0)
                    // Over a sharp wallpaper the queue and lyrics get a solid glass panel,
                    // so the picture never wins over the text.
                    .background {
                        if wallpaper.isActive {
                            PanelBackground()
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08)))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .animation(.snappy(duration: 0.25), value: router.panelTab)
                    .offset(y: appeared ? 0 : 30)
                    .opacity(appeared ? 1 : 0)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                // Full width, so the cover sits in the middle once the panel is hidden.
                .frame(maxWidth: .infinity)
                .padding(40)
                .environment(\.colorScheme, .dark)
            } else {
                Color.clear.background(.background)
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button { withAnimation(.spring(duration: 0.45, bounce: 0)) { router.showNowPlaying = false } } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).padding(8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(router.videoFullscreen ? nil : .cancelAction)
            .help("Close (Esc)")
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            if player.current != nil {
                Button { withAnimation(.snappy(duration: 0.35)) { router.nowPlayingPanel.toggle() } } label: {
                    Image(systemName: "sidebar.right").font(.title3.weight(.semibold)).padding(8)
                        .foregroundStyle(router.nowPlayingPanel ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(router.nowPlayingPanel ? "Hide lyrics and Up Next" : "Show lyrics and Up Next")
                .padding(12)
                .environment(\.colorScheme, .dark)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.2).delay(0.05)) { appeared = true }
            // The Video switch lives here; start fetching the video now so it's quick.
            if let s = player.current, !player.videoMode { player.prefetch(s, video: true) }
        }
        .onChange(of: hasLyrics, initial: true) { _, has in
            guard let has else { return }
            withAnimation(.snappy) {
                if !has, router.panelTab == .lyrics {
                    router.panelTab = .queue
                    leftLyricsForMissing = true
                } else if has, leftLyricsForMissing, router.panelTab == .queue {
                    router.panelTab = .lyrics
                    leftLyricsForMissing = false
                }
            }
        }
    }
}

/// Up Next inside Now Playing: transparent rows on the album colour, no list chrome.
/// What already played sits above Now Playing, out of view until you scroll up. A
/// scroll that stops with Now Playing near the top settles it there.
struct NowPlayingQueue: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var position = ScrollPosition(idType: String.self)
    /// How far Now Playing sits below the top: more than 0 while history shows.
    @State private var nowOffset: CGFloat = 0

    var body: some View {
        let played = player.played.suffix(50)
        let firstPlayed = player.index - played.count
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
              // One block for history and Now Playing: as the stack's first child it is
              // always built, so the jump to "now" finds its target.
              VStack(alignment: .leading, spacing: 2) {
                if !played.isEmpty {
                    Text("Played").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 8)
                    ForEach(Array(played.enumerated()), id: \.offset) { i, s in
                        QueueRow(song: s, current: false)
                            .padding(8)
                            .opacity(0.6)
                            .contentShape(Rectangle())
                            .modifier(HoverHighlight())
                            .onTapGesture { player.jump(to: firstPlayed + i) }
                            .draggable(library.dragPayload([s])) { DragPreview(songs: [s]) }
                            .contextMenu { SongMenu(songs: [s]) }
                    }
                    Color.clear.frame(height: 12)
                }
                if let s = player.current {
                    Text("Now Playing").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 8)
                        .id("now")
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { nowOffset = $0 }
                    QueueRow(song: s, current: true)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.12)))
                        .draggable(library.dragPayload([s])) { DragPreview(songs: [s]) }
                }
              }
                HStack {
                    Text("Up Next").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    UpNextActions()
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
                if player.upNext.isEmpty {
                    Text("Nothing queued").foregroundStyle(.secondary).padding(8)
                }
                ForEach(QueueEntry.list(player.upNext)) { entry in
                    let i = entry.index, s = entry.song
                    QueueRow(song: s, current: false)
                        .padding(8)
                        .contentShape(Rectangle())
                        .modifier(HoverHighlight())
                        .onTapGesture { player.jump(to: player.index + 1 + i) }
                        .draggable(library.dragPayload([s])) { DragPreview(songs: [s]) }
                        .contextMenu { SongMenu(songs: [s], upNextIndex: i) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .scrollPosition($position, anchor: .top)
        .scrollIndicators(.hidden)
        // After the first layout pass, so the rows above are measured.
        .task {
            await Task.yield()
            position.scrollTo(id: "now", anchor: .top)
        }
        .onChange(of: player.current?.id) { position.scrollTo(id: "now", anchor: .top) }
        .onScrollPhaseChange { _, phase in
            // Only when close: further up you're reading what played, and the list stays.
            guard phase == .idle, nowOffset > 1, nowOffset < 140 else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { position.scrollTo(id: "now", anchor: .top) }
        }
    }
}

/// Song Info from the right-click menu: what the song is, where it's from, how it's doing.
struct SongInfoView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    let song: Song
    @State private var info: SongInfo?

    var body: some View {
        let length = player.current?.id == song.id && player.length > 0 ? player.length : song.duration
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Artwork(hue: song.hue, url: song.artwork, side: 64, radius: 8)
                Text(song.title).font(.title3.bold()).lineLimit(3).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 10) {
                row("Artist") { ArtistLink(song: song) }
                if !song.album.isEmpty { row("Album") { AlbumLink(song: song) } }
                if let channel = info?.channel, channel != song.artist { row("Uploaded by") { Text(channel) } }
                if length > 0 { row("Length") { Text(formatTime(length)) } }
                if let views = info?.views { row("Views") { Text(views.formatted()) } }
                if let date = info?.published { row("Released") { Text(date.formatted(date: .long, time: .omitted)) } }
                if let kind = kindName { row("Type") { Text(kind) } }
            }
            HStack {
                Button { library.copyLink(song.id, song: true) } label: { Label("Copy Link", systemImage: "link") }
                Button("Copy Spotify Link") { library.copySpotifyLink(song) }
                Spacer()
                Button("Done") { router.infoSong = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
        .animation(.easeOut(duration: 0.2), value: info != nil)
        .task(id: song.id) { info = await library.info(song.id) }
        // The artist and album links open a page; the sheet makes way for it.
        .onChange(of: router.current) { router.infoSong = nil }
    }

    private var kindName: String? {
        switch info?.type ?? song.videoType {
        case "MUSIC_VIDEO_TYPE_ATV": "Song"
        case "MUSIC_VIDEO_TYPE_OMV": "Official music video"
        case "MUSIC_VIDEO_TYPE_UGC": "Video upload"
        case "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": "Podcast episode"
        default: nil
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            value().lineLimit(2)
        }
    }
}

/// Segmented switch with a highlight that slides between options.
struct PillSwitch<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { label, value in
                Button {
                    guard selection != value else { return }
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = value }
                } label: {
                    Text(label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background {
                            if selection == value {
                                Capsule().fill(.white.opacity(0.18))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.2)))
    }
}

/// Animated bars for the song that's playing; still while paused.
struct PlayingIndicator: View {
    @Environment(Player.self) private var player

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4))
            EqualizerBars(playing: player.isPlaying, color: .white).frame(width: 14, height: 14)
        }
    }
}

/// Three bars bouncing like a level meter. Core Animation moves them on the GPU: the
/// SF Symbol effect used before redrew on the main thread every frame, and with a
/// song on screen kept Tide at over half a CPU core.
struct EqualizerBars: NSViewRepresentable {
    let playing: Bool
    var color: Color = .primary

    func makeNSView(context: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.update(color: NSColor(color).cgColor, playing: playing)
    }
}

final class EqualizerBarsView: NSView {
    private let bars = (0..<3).map { _ in CALayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        for (i, bar) in bars.enumerated() {
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            root.addSublayer(bar)
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.25
            bounce.toValue = 1
            bounce.duration = [0.42, 0.55, 0.36][i]
            bounce.timeOffset = Double(i) * 0.17
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(bounce, forKey: "bounce")
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let width = bounds.width / 5
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: width * (CGFloat(i) * 2 + 0.5), y: 0)
            bar.cornerRadius = width / 2
        }
    }

    func update(color: CGColor, playing: Bool) {
        bars.forEach { $0.backgroundColor = color }
        guard let root = layer, (root.speed > 0) != playing else { return }
        if playing {
            let paused = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            let now = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = now
        }
    }
}

/// A queue row's identity: its place and its song. Place alone let a row keep the
/// previous song's cover and name when the queue changed.
struct QueueEntry: Identifiable {
    let index: Int
    let song: Song
    /// The song, and which copy of it when queued twice: not its place, so a row
    /// keeps its identity when shuffling moves it and slides there.
    let id: String

    static func list(_ songs: [Song]) -> [QueueEntry] {
        var seen: [String: Int] = [:]
        return songs.enumerated().map { offset, song in
            let copy = seen[song.id, default: 0]
            seen[song.id] = copy + 1
            return QueueEntry(index: offset, song: song, id: "\(song.id)#\(copy)")
        }
    }
}
