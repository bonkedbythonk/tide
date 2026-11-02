import SwiftUI

struct PlayerBar: View {
    var body: some View {
        HStack(spacing: 16) {
            NowPlayingInfo().frame(width: 280, alignment: .leading)
            Spacer(minLength: 0)
            TransportControls().frame(minWidth: 320, maxWidth: 540)
            Spacer(minLength: 0)
            PlayerExtras().frame(width: 320, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(.bar)
    }
}

/// Current song. Two-finger swipe over it skips; click the art for Now Playing.
struct NowPlayingInfo: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            if let s = player.current {
                HStack(spacing: 12) {
                    Artwork(hue: s.hue, url: s.artwork, side: 52, radius: 6)
                        .onTapGesture { withAnimation(.snappy) { router.showNowPlaying.toggle() } }
                        .help("Show Now Playing")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .id(s.id)
                .transition(.push(from: player.skipForward ? .trailing : .leading))
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

struct TransportControls: View {
    @Environment(Player.self) private var player

    var body: some View {
        let duration = player.current?.playDuration ?? 1
        VStack(spacing: 4) {
            HStack(spacing: 24) {
                Button { player.shuffle.toggle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.shuffle ? Color.accentColor : Color.secondary)
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
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                }
                .help("Repeat")
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(formatTime(player.position)).frame(width: 40, alignment: .trailing)
                Slider(
                    value: Binding(get: { min(player.position, duration) }, set: { player.seek($0) }),
                    in: 0...duration
                )
                .controlSize(.mini)
                .disabled(player.current == nil)
                Text(formatTime(duration)).frame(width: 40, alignment: .leading)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

struct PlayerExtras: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 14) {
            Button { player.videoMode.toggle() } label: {
                Image(systemName: player.videoMode ? "play.rectangle.fill" : "play.rectangle")
                    .foregroundStyle(player.videoMode ? Color.accentColor : Color.secondary)
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
            PopoverButton(symbol: "hifispeaker.and.appletv", help: "Devices") { DevicesPopover() }
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
        let active = router.panelVisible && router.panelTab == tab
        return Button { router.togglePanel(tab) } label: {
            Image(systemName: symbol).foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .help(help)
    }
}

struct PopoverButton<Content: View>: View {
    let symbol: String
    let help: String
    @ViewBuilder let content: Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: symbol).foregroundStyle(open ? Color.accentColor : Color.secondary)
        }
        .help(help)
        .popover(isPresented: $open, arrowEdge: .top) { content }
    }
}

struct DevicesPopover: View {
    @Environment(Player.self) private var player
    private let devices: [(String, String)] = [
        ("This Mac", "laptopcomputer"),
        ("Living Room (AirPlay)", "homepod.fill"),
        ("AirPods Pro", "airpodspro"),
        ("iPhone", "iphone"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Play on").font(.headline).padding(.bottom, 4)
            ForEach(devices, id: \.0) { name, symbol in
                Button { player.device = name } label: {
                    HStack {
                        Image(systemName: symbol).frame(width: 22)
                        Text(name)
                        Spacer()
                        if player.device == name {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HoverHighlight())
            }
            Divider().padding(.vertical, 4)
            Text("iPhone playback and remote control are a mockup: they need the companion iPhone app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 270)
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
            Toggle("Gapless playback", isOn: $player.gapless)
            Toggle("Normalize loudness", isOn: $player.normalize)
            Picker("Equalizer", selection: $player.eq) {
                ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Sleep timer", selection: $player.sleepTimer) {
                ForEach(SleepTimer.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("Controls only. The sample plays no audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 330, height: 290)
    }
}

struct SidePanelView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            Picker("", selection: $router.panelTab) {
                Text("Up Next").tag(PanelTab.queue)
                Text("Lyrics").tag(PanelTab.lyrics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            switch router.panelTab {
            case .queue: QueueView()
            case .lyrics: LyricsView(fontSize: 20)
            }
        }
    }
}

struct QueueView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        List {
            if let s = player.current {
                Section("Now Playing") { QueueRow(song: s, current: true) }
            }
            Section("Up Next") {
                if player.upNext.isEmpty {
                    Text("Drop songs here to queue them").foregroundStyle(.secondary)
                }
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, s in
                    QueueRow(song: s, current: false)
                        .contentShape(Rectangle())
                        .onTapGesture { player.jump(to: player.index + 1 + i) }
                        .contextMenu { SongMenu(songs: [s]) }
                }
                .onMove { player.moveUpNext(from: $0, to: $1) }
                .onDelete { player.removeUpNext(at: $0) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .dropDestination(for: String.self) { items, _ in
            let songs = library.songs(SongDrag.ids(from: items))
            guard !songs.isEmpty else { return false }
            player.addToQueue(songs)
            library.showToast(songs.count == 1 ? "Added to queue" : "Added \(songs.count) songs to queue")
            return true
        }
    }
}

struct QueueRow: View {
    let song: Song
    let current: Bool

    var body: some View {
        HStack(spacing: 10) {
            Artwork(hue: song.hue, url: song.artwork, side: 36, radius: 4, symbol: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1).foregroundStyle(current ? Color.accentColor : Color.primary)
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
    var fontSize: CGFloat = 20

    var body: some View {
        if let song = player.current {
            let lines = FakeLyrics.lines(for: song)
            let currentIndex = lines.lastIndex { $0.time <= player.position } ?? -1
            ScrollViewReader { proxy in
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
                        Text("Placeholder lyrics. Real ones would come from YouTube Music or LRCLIB.")
                            .font(.caption).foregroundStyle(.tertiary).padding(.top, 20)
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
            .id(song.id)
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note")
        }
    }
}

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @State private var tab = PanelTab.lyrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let s = player.current {
                LinearGradient(
                    colors: [Color(hue: s.hue, saturation: 0.6, brightness: 0.55), Color(hue: s.hue, saturation: 0.4, brightness: 0.15)],
                    startPoint: .top, endPoint: .bottom
                )
                .overlay(.ultraThinMaterial)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: s.id)

                HStack(alignment: .center, spacing: 48) {
                    VStack(spacing: 18) {
                        if player.videoMode {
                            AmbientVideo(song: s)
                                .frame(width: 520)
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
                                .id(s.id)
                                .transition(.push(from: player.skipForward ? .trailing : .leading))
                        } else {
                            Artwork(hue: s.hue, url: s.artwork, side: 340, radius: 14)
                                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                                .id(s.id)
                                .transition(.push(from: player.skipForward ? .trailing : .leading))
                                .onHover { router.pointerOverPlayerSong = $0 }
                        }
                        Picker("", selection: Binding(get: { player.videoMode }, set: { player.videoMode = $0 })) {
                            Text("Song").tag(false)
                            Text("Video").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 160)
                        VStack(spacing: 4) {
                            Text(s.title).font(.title.bold()).lineLimit(1)
                            Text(s.album.isEmpty ? s.artist : "\(s.artist) — \(s.album)").font(.title3).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 18) {
                            LikeButton(songID: s.id)
                            StandaloneAddButton(songIDs: [s.id])
                        }
                        .font(.title2)
                    }
                    .frame(width: player.videoMode ? 520 : 380)
                    .animation(.snappy(duration: 0.3), value: s.id)
                    .animation(.snappy(duration: 0.3), value: player.videoMode)

                    VStack(spacing: 8) {
                        Picker("", selection: $tab) {
                            Text("Lyrics").tag(PanelTab.lyrics)
                            Text("Up Next").tag(PanelTab.queue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        switch tab {
                        case .lyrics: LyricsView(fontSize: 28)
                        case .queue: QueueView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(40)
                .environment(\.colorScheme, .dark)
            } else {
                Color.clear.background(.background)
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button { withAnimation(.snappy) { router.showNowPlaying = false } } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).padding(8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(router.videoFullscreen ? nil : .cancelAction)
            .help("Close (Esc)")
            .padding(12)
        }
    }
}
