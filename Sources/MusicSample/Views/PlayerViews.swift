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
            Spacer(minLength: 0)
            PlayerExtras().frame(width: 320, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background {
            if wallpaper.isActive {
                // Its slice of the wallpaper, under the same bar material.
                PanelBackground()
            } else {
                Rectangle().fill(.bar)
            }
        }
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
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            if let s = player.current {
                HStack(spacing: 12) {
                    Artwork(hue: s.hue, url: s.artwork, side: 52, radius: 6)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: router.showNowPlaying ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(3)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(1)
                        if let error = player.lastError {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                        } else if player.isLoading {
                            Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ArtistLink(song: s).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
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
        // Songs from Home arrive without a length; show none until mpv knows it.
        let known = player.length > 0
        let duration = known ? player.length : 1
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
                Text(known ? formatTime(player.position) : "–:––").frame(width: 40, alignment: .trailing)
                Slider(
                    value: Binding(get: { known ? min(player.position, duration) : 0 }, set: { player.seek($0) }),
                    in: 0...duration
                )
                .controlSize(.mini)
                .disabled(!known)
                Text(known ? formatTime(duration) : "–:––").frame(width: 40, alignment: .leading)
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
        let active = router.panelTab == tab && (router.showNowPlaying || router.panelVisible)
        return Button {
            if router.showNowPlaying {
                withAnimation(.snappy) { router.panelTab = tab }
            } else {
                router.togglePanel(tab)
            }
        } label: {
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
            Toggle("Autoplay similar songs", isOn: $player.autoplay)
                .help("When the queue runs out, keep going with YouTube Music's radio for the last song")
            Toggle("Gapless playback", isOn: $player.gapless)
            Toggle("Match YouTube Music loudness", isOn: $player.matchLoudness)
            Toggle("Smooth transitions", isOn: $player.smoothTransitions)
                .help("Fade the volume on pause, resume and skip")
            Picker("Equalizer", selection: $player.eq) {
                ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Sleep timer", selection: $player.sleepTimer) {
                ForEach(SleepTimer.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("Gapless, EQ and sleep timer aren't wired up yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 330)
    }
}

struct SidePanelView: View {
    @Environment(Router.self) private var router
    @Environment(WallpaperStore.self) private var wallpaper

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
        .background { if wallpaper.isActive { Rectangle().fill(.regularMaterial).ignoresSafeArea() } }
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
                ForEach(QueueEntry.list(player.upNext)) { entry in
                    let i = entry.index, s = entry.song
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

struct NowPlayingView: View {
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
                        .transition(.push(from: player.skipForward ? .trailing : .leading))
                        .scaleEffect(appeared ? 1 : 0.85)
                        .opacity(appeared ? 1 : 0)

                        PillSwitch(options: [("Song", false), ("Video", true)],
                                   selection: Binding(get: { player.videoMode }, set: { player.videoMode = $0 }))
                        VStack(spacing: 4) {
                            Text(s.title).font(.title.bold()).lineLimit(1)
                            HStack(spacing: 0) {
                                ArtistLink(song: s)
                                if !s.album.isEmpty { Text(" — \(s.album)") }
                            }
                            .font(.title3).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .id(s.id)
                        .transition(.opacity)
                        HStack(spacing: 18) {
                            LikeButton(songID: s.id)
                            StandaloneAddButton(songIDs: [s.id])
                        }
                        .font(.title2)
                    }
                    .frame(width: player.videoMode && player.videoAspect >= 1.2 ? 520 : 380)
                    .frame(maxHeight: .infinity)
                    .animation(.snappy(duration: 0.35), value: s.id)
                    .animation(.snappy(duration: 0.35), value: player.videoMode)

                    VStack(spacing: 8) {
                        PillSwitch(options: [("Lyrics", PanelTab.lyrics), ("Up Next", PanelTab.queue)],
                                   selection: $router.panelTab)
                        Group {
                            switch router.panelTab {
                            case .lyrics: LyricsView(fontSize: 28)
                            case .queue: NowPlayingQueue()
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
                }
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
                } else if has, leftLyricsForMissing {
                    router.panelTab = .lyrics
                    leftLyricsForMissing = false
                }
            }
        }
    }
}

/// Up Next inside Now Playing: transparent rows on the album colour, no list chrome.
struct NowPlayingQueue: View {
    @Environment(Player.self) private var player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let s = player.current {
                    Text("Now Playing").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 8)
                    QueueRow(song: s, current: true)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.12)))
                }
                Text("Up Next").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 12)
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
                        .contextMenu { SongMenu(songs: [s]) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
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
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
        }
    }
}

/// A queue row's identity: its place and its song. Place alone let a row keep the
/// previous song's cover and name when the queue changed.
struct QueueEntry: Identifiable {
    let index: Int
    let song: Song
    var id: String { "\(index)-\(song.id)" }

    static func list(_ songs: [Song]) -> [QueueEntry] {
        songs.enumerated().map { QueueEntry(index: $0.offset, song: $0.element) }
    }
}
