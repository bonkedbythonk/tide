import SwiftUI

struct HomeTab: View {
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(library.home) { ShelfView(shelf: $0) }
                    // Reaching the bottom asks YouTube for the next few sections.
                    Color.clear.frame(height: 1).task { await library.loadMoreHome(pages: 2) }
                }
                .padding(.vertical)
            }
            .overlay {
                if case .failed(let message) = library.state {
                    ContentUnavailableView("Couldn't load Home", systemImage: "wifi.exclamationmark", description: Text(message))
                } else if library.home.isEmpty {
                    ProgressView()
                }
            }
            .refreshable { await library.refresh() }
            .navigationTitle("Home")
            .pageDestination()
        }
    }
}

struct SearchTab: View {
    @Environment(Library.self) private var library
    @State private var query = ""
    @State private var results: [HomeShelf] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(results) { ShelfView(shelf: $0) }
                }
                .padding(.vertical)
            }
            .overlay { if searching { ProgressView() } }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Songs, albums, artists")
            .onSubmit(of: .search) {
                let q = query
                searching = true
                Task {
                    results = await library.search(q)
                    searching = false
                }
            }
            .pageDestination()
        }
    }
}

struct LibraryTab: View {
    @Environment(Library.self) private var library
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(value: Library.likedID) { Label("Liked Songs", systemImage: "heart.fill") }
                if !library.playlists.isEmpty {
                    Section("Playlists") { ForEach(library.playlists) { row($0) } }
                }
                if !library.savedAlbums.isEmpty {
                    Section("Albums") { ForEach(library.savedAlbums) { row($0) } }
                }
            }
            .refreshable { await library.refresh() }
            .navigationTitle("Library")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .pageDestination()
        }
    }

    private func row(_ item: MediaItem) -> some View {
        NavigationLink(value: item.id) {
            HStack(spacing: 12) {
                Cover(url: item.artwork, pixels: 120).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

extension View {
    /// Playlists, albums, artists and mixes open on their own page.
    func pageDestination() -> some View {
        navigationDestination(for: String.self) { PageScreen(id: $0) }
    }
}

/// A playlist, album, artist or mix.
struct PageScreen: View {
    @Environment(Library.self) private var library
    @Environment(Remote.self) private var remote
    let id: String

    var body: some View {
        let page = library.pages[id]
        let songs = library.songs(in: id)
        List {
            if let page {
                VStack(spacing: 8) {
                    Cover(url: page.artwork, pixels: 544).frame(width: 200)
                    Text(page.title).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(page.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button { remote.play(songs, at: 0) } label: { Label("Play", systemImage: "play.fill") }
                        Button {
                            let shuffled = songs.shuffled()
                            remote.play(shuffled, at: 0)
                        } label: { Label("Shuffle", systemImage: "shuffle") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(songs.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                    SongRow(song: song) { remote.play(songs, at: i) }
                }
                ForEach(page.shelves ?? []) { shelf in
                    ShelfView(shelf: shelf)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if page == nil { ProgressView() } }
        .navigationBarTitleDisplayMode(.inline)
        .task { _ = await library.page(id) }
    }
}

struct SongRow: View {
    let song: Song
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Cover(url: song.artwork, pixels: 120).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).lineLimit(1)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if song.duration > 0 {
                    Text(formatTime(song.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }
}

/// One Home or search section: plain songs as a grid of rows, everything else as cards.
struct ShelfView: View {
    @Environment(Remote.self) private var remote
    let shelf: HomeShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title).font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                if shelf.isSongList {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(52)), count: 4), spacing: 16) {
                        ForEach(Array(shelf.songs.enumerated()), id: \.offset) { i, song in
                            SongRow(song: song) { remote.play(shelf.songs, at: i) }.frame(width: 300)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shelf.items) { card($0) }
                    }
                    .padding(.horizontal)
                }
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder private func card(_ item: ShelfItem) -> some View {
        switch item {
        case .song(let song, _):
            Button {
                let songs = shelf.songs
                remote.play(songs, at: songs.firstIndex(of: song) ?? 0)
            } label: {
                CardLabel(title: song.title, subtitle: song.artist, artwork: song.artwork, round: false)
            }
            .buttonStyle(.plain)
        case .media(let m):
            NavigationLink(value: m.id) {
                CardLabel(title: m.title, subtitle: m.subtitle, artwork: m.artwork, round: m.kind == .artist)
            }
            .buttonStyle(.plain)
        }
    }
}

struct CardLabel: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    let round: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Cover(url: artwork, pixels: 300)
                .frame(width: 150, height: 150)
                .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
            Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
    }
}
