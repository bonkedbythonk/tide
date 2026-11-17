import SwiftUI

/// Cover art, or a gradient from the item's hue while it loads or when there is none.
struct Cover: View {
    let hue: Double
    let url: URL?
    let side: CGFloat
    var radius: CGFloat = 12

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.9),
                                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note").font(.system(size: side * 0.3)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Loads something from the Mac once, with a spinner and an error line meanwhile.
struct Loaded<T: Decodable, Content: View>: View {
    @Environment(MacLink.self) private var link
    @Environment(\.scenePhase) private var scenePhase
    let path: String
    var query: [URLQueryItem] = []
    /// Loads again, quietly behind what's showing, whenever this comes back into view.
    var refreshes = false
    @ViewBuilder let content: (T) -> Content
    @State private var value: T?
    @State private var error: String?

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let error {
                VStack(spacing: 30) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load() } }.buttonStyle(PillStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path + query.description) { await load() }
        .onAppear { if refreshes, value != nil { Task { await load(quietly: true) } } }
        .onChange(of: scenePhase) { _, phase in
            if refreshes, phase == .active, value != nil { Task { await load(quietly: true) } }
        }
    }

    /// `quietly`: keeps what's showing if the reload fails.
    private func load(quietly: Bool = false) async {
        if !quietly { error = nil }
        do { value = try await link.get(path, query) } catch { if !quietly { self.error = error.localizedDescription } }
    }
}

/// A song as the Mac shows it in Quick picks: small cover, title, artist and album.
struct SongTile: View {
    @Environment(TVPlayer.self) private var player
    let song: Song

    var body: some View {
        let playing = player.current?.id == song.id
        HStack(spacing: 22) {
            Cover(hue: song.hue, url: song.artwork, side: 96, radius: 10)
                .overlay {
                    if playing {
                        Image(systemName: "waveform").font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white).shadow(radius: 6)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(song.title).font(.system(size: 29, weight: .medium))
                    .foregroundStyle(playing ? Tide.blue : .white).lineLimit(1)
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 23)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A playlist, album or artist cover with its name under it.
struct MediaCard: View {
    let title: String
    let subtitle: String
    let hue: Double
    let artwork: URL?
    var side: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Cover(hue: hue, url: artwork, side: side, radius: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
    }
}

/// Hold Select on a song for these, as in the Apple TV's own apps.
struct SongMenu: ViewModifier {
    @Environment(TVPlayer.self) private var player
    let song: Song

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadio(song) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }
            Button("Add to Queue", systemImage: "text.append") { player.addToQueue(song) }
        }
    }
}

extension View {
    func songMenu(_ song: Song) -> some View { modifier(SongMenu(song: song)) }
}

struct SectionHeader: View {
    let title: String
    var playAll: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 40, weight: .bold))
            Spacer()
            if let playAll {
                Button(action: playAll) { Label("Play all", systemImage: "play.fill") }.buttonStyle(PillStyle())
            }
        }
    }
}

/// One Home or search section: songs as Tide's three-column grid, everything else as covers.
struct ShelfView: View {
    @Environment(TVPlayer.self) private var player
    let shelf: HomeShelf

    var body: some View {
        let songs = shelf.songs
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: shelf.title, playAll: songs.isEmpty ? nil : { player.play(songs) })
            if shelf.isSongList {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 30), count: 3), spacing: 8) {
                    ForEach(Array(songs.prefix(12).enumerated()), id: \.offset) { i, song in
                        Button { player.play(songs, at: i) } label: { SongTile(song: song) }
                            .buttonStyle(RowStyle())
                            .songMenu(song)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 50) {
                        ForEach(shelf.items) { item in
                            switch item {
                            case .song(let song, _):
                                Button { player.play(songs, at: songs.firstIndex(of: song) ?? 0) } label: {
                                    MediaCard(title: song.title, subtitle: song.artist, hue: song.hue, artwork: song.artwork)
                                }
                                .buttonStyle(CardStyle())
                                .songMenu(song)
                            case .media(let media):
                                NavigationLink(value: media) {
                                    MediaCard(title: media.title, subtitle: media.subtitle, hue: media.hue, artwork: media.artwork)
                                }
                                .buttonStyle(CardStyle())
                            }
                        }
                    }
                    .padding(.vertical, 30)
                }
                // Edge to edge, with the page's margin inside: covers stay drawn until
                // they're really off screen instead of vanishing at the margin.
                .contentMargins(.horizontal, 90, for: .scrollContent)
                .padding(.horizontal, -90)
                .scrollClipDisabled()
            }
        }
    }
}

struct Shelves<Header: View>: View {
    let shelves: [HomeShelf]
    @ViewBuilder var header: Header

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 60) {
                header
                ForEach(shelves) { ShelfView(shelf: $0) }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 40)
        }
        .navigationDestination(for: MediaItem.self) { PageView(item: $0) }
    }
}

struct HomeTab: View {
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        Loaded(path: "home", refreshes: true) { (shelves: [HomeShelf]) in
            Shelves(shelves: shelves) {
                VStack(alignment: .leading, spacing: 30) {
                    Text(greeting).font(.system(size: 64, weight: .bold))
                    MoodField()
                }
            }
        }
    }
}

/// The AI DJ, as on the Mac's Home: describe what you want to hear and Tide fills Up
/// Next with it and keeps going. Type with the remote or hold its mic button to speak.
struct MoodField: View {
    @Environment(TVPlayer.self) private var player
    @State private var text = ""

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold)).foregroundStyle(Tide.blue)
            TextField("What do you want to hear?", text: $text)
                .onSubmit {
                    player.startMood(text)
                    text = ""
                }
                .frame(maxWidth: 900)
            if let pending = player.moodLoading {
                ProgressView()
                Text("Finding \(pending)...").font(.system(size: 24)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            } else if let mood = player.mood {
                Button { player.endMood() } label: { Label("Mood: \(mood)", systemImage: "xmark") }
                    .buttonStyle(PillStyle())
            }
        }
    }
}

struct SearchTab: View {
    @State private var text = ""
    @State private var query = ""

    var body: some View {
        Group {
            if query.isEmpty {
                Color.clear
            } else {
                Loaded(path: "search", query: [URLQueryItem(name: "q", value: query)]) { (shelves: [HomeShelf]) in
                    Shelves(shelves: shelves) { EmptyView() }
                }
            }
        }
        .searchable(text: $text, prompt: "Songs, albums, artists")
        // Search once typing pauses, not on every letter.
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { query = text.trimmingCharacters(in: .whitespaces) }
        }
    }
}

struct LibraryTab: View {
    var body: some View {
        Loaded(path: "library", refreshes: true) { (list: TVProtocol.LibraryList) in
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text("Library").font(.system(size: 64, weight: .bold))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(270), spacing: 70), count: 5),
                              alignment: .leading, spacing: 60) {
                        NavigationLink(value: MediaItem(id: "VLLM", title: "Liked Songs", subtitle: "Playlist",
                                                        artwork: nil, kind: .playlist)) {
                            VStack(alignment: .leading, spacing: 14) {
                                ZStack {
                                    LinearGradient(colors: [Color(red: 0.95, green: 0.3, blue: 0.5), Color(red: 0.45, green: 0.2, blue: 0.85)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                    Image(systemName: "heart.fill").font(.system(size: 90)).foregroundStyle(.white)
                                }
                                .frame(width: 270, height: 270)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                Text("Liked Songs").font(.system(size: 26, weight: .semibold))
                                Text("Playlist").font(.system(size: 22)).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .buttonStyle(CardStyle())
                        ForEach(list.playlists + list.albums) { item in
                            NavigationLink(value: item) {
                                MediaCard(title: item.title, subtitle: item.subtitle, hue: item.hue, artwork: item.artwork)
                            }
                            .buttonStyle(CardStyle())
                        }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 40)
            }
            .navigationDestination(for: MediaItem.self) { PageView(item: $0) }
        }
    }
}

/// A playlist, album, mix or artist, laid out like the Mac's: header, then the songs in a panel.
struct PageView: View {
    @Environment(TVPlayer.self) private var player
    let item: MediaItem

    var body: some View {
        Loaded(path: "page/" + item.id) { (page: PageData) in
            ScrollView {
                VStack(alignment: .leading, spacing: 50) {
                    HStack(alignment: .bottom, spacing: 50) {
                        Cover(hue: item.hue, url: page.artwork ?? item.artwork, side: 320, radius: 20)
                            .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                        VStack(alignment: .leading, spacing: 16) {
                            Text(page.title).font(.system(size: 66, weight: .bold)).lineLimit(2)
                            Text(details(page)).font(.system(size: 28)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            HStack(spacing: 24) {
                                Button { player.play(page.songs) } label: { Label("Play", systemImage: "play.fill") }
                                    .buttonStyle(PillStyle(prominent: true))
                                Button { player.play(page.songs.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                                    .buttonStyle(PillStyle())
                            }
                            .disabled(page.songs.isEmpty)
                            .padding(.top, 10)
                        }
                    }
                    Panel {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(page.songs.enumerated()), id: \.offset) { i, song in
                                Button { player.play(page.songs, at: i) } label: { SongRow(song: song, number: i + 1) }
                                    .buttonStyle(RowStyle())
                                    .songMenu(song)
                            }
                        }
                        .padding(20)
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 40)
            }
        }
    }

    private func details(_ page: PageData) -> String {
        let minutes = Int(page.songs.reduce(0) { $0 + $1.duration } / 60)
        let count = "\(page.songs.count) song" + (page.songs.count == 1 ? "" : "s")
        return [page.subtitle, count, minutes > 0 ? "\(minutes) min" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SongRow: View {
    @Environment(TVPlayer.self) private var player
    let song: Song
    var number: Int?
    /// Off in narrow places like Up Next, where the title needs the room.
    var showsAlbum = true

    var body: some View {
        let playing = player.current?.id == song.id
        HStack(spacing: 26) {
            if let number {
                Group {
                    if playing { Image(systemName: "waveform").foregroundStyle(Tide.blue) } else { Text("\(number)") }
                }
                .font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                .frame(width: 50)
            }
            Cover(hue: song.hue, url: song.artwork, side: 72, radius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.system(size: 28, weight: .medium))
                    .foregroundStyle(playing ? Tide.blue : .white).lineLimit(1)
                Text(song.artist).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if showsAlbum {
                Text(song.album).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    .frame(width: 360, alignment: .leading)
            }
            Text(song.duration > 0 ? formatTime(song.duration) : "")
                .font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
    }
}
