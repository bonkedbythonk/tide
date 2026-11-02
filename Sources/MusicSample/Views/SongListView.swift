import AppKit
import SwiftUI

/// Loads a playlist / album / mix / artist page, then shows it.
struct PageView: View {
    @Environment(Library.self) private var library
    let id: String
    var fallbackTitle = ""

    var body: some View {
        Group {
            if let page = library.pages[id] {
                SongListView(page: page, songs: library.songs(in: id),
                             playlistID: library.playlist(id) != nil ? id : nil)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) { _ = await library.page(id) }
    }
}

struct SongRowItem: Identifiable {
    let number: Int
    let song: Song
    var id: String { song.id }
    var title: String { song.title }
    var artist: String { song.artist }
    var album: String { song.album }
    var duration: TimeInterval { song.duration }
}

/// Sortable columns, Cmd-F filter, multi-select and drag.
struct SongListView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let page: PageData
    let songs: [Song]
    let playlistID: String?

    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SongRowItem.number)]
    @State private var filter = ""
    @State private var filterFocused = false

    private var items: [SongRowItem] {
        var seen = Set<String>()
        let base = songs.filter { seen.insert($0.id).inserted }.enumerated().map { SongRowItem(number: $0 + 1, song: $1) }
        let filtered = filter.isEmpty ? base : base.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.artist.localizedCaseInsensitiveContains(filter)
                || $0.album.localizedCaseInsensitiveContains(filter)
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = items
        let visibleSongs = rows.map(\.song)
        let currentID = player.current?.id
        VStack(spacing: 0) {
            header(visibleSongs)
            Table(of: SongRowItem.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("#", value: \.number) { item in
                    if currentID == item.id {
                        Image(systemName: "waveform")
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
                    } else {
                        Text("\(item.number)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .width(38)
                TableColumn("Title", value: \.title) { item in
                    HStack(spacing: 8) {
                        Artwork(hue: item.song.hue, url: item.song.artwork, side: 28, radius: 4, symbol: nil)
                        Text(item.title)
                            .foregroundStyle(currentID == item.id ? Color.accentColor : Color.primary)
                    }
                }
                .width(min: 180, ideal: 300)
                TableColumn("Artist", value: \.artist)
                TableColumn("Album", value: \.album)
                TableColumn("") { item in
                    HStack(spacing: 10) {
                        LikeButton(songID: item.id)
                        StandaloneAddButton(songIDs: [item.id])
                    }
                }
                .width(52)
                TableColumn("Time", value: \.duration) { item in
                    Text(item.duration > 0 ? formatTime(item.duration) : "")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .width(50)
            } rows: {
                ForEach(rows) { item in
                    TableRow(item)
                        .draggable(SongDrag.payload(dragIDs(for: item, in: rows)))
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                SongMenu(songs: library.songs(orderedIDs(ids, in: rows)), playlistID: playlistID)
            } primaryAction: { ids in
                if let id = ids.first, let s = library.song(id) { player.play(s, in: visibleSongs) }
            }
            .onChange(of: selection) { _, new in
                guard new.count == 1, let id = new.first, let s = library.song(id),
                      NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) else { return }
                ClickToPlay.arm { player.play(s, in: visibleSongs) }
            }
        }
        .searchable(text: $filter, isPresented: $filterFocused, placement: .toolbar, prompt: "Filter songs")
        .background {
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        }
    }

    private func header(_ visible: [Song]) -> some View {
        let minutes = Int(visible.reduce(0) { $0 + $1.duration } / 60)
        return HStack(alignment: .bottom, spacing: 20) {
            Artwork(hue: Double(page.id.stableHash % 1000) / 1000, url: page.artwork, side: 150, radius: 10)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(page.title).font(.system(size: 34, weight: .bold)).lineLimit(1)
                Text([page.subtitle, "\(visible.count) songs", minutes > 0 ? "\(minutes) min" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " • "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Button { player.playAll(visible) } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { player.playAll(visible, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    if selection.count > 1 {
                        Text("\(selection.count) selected — drag them onto a playlist in the sidebar")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
            Spacer()
        }
        .padding(24)
    }

    /// Dragging a selected row drags the whole selection, in the order shown.
    private func dragIDs(for item: SongRowItem, in rows: [SongRowItem]) -> [String] {
        guard selection.contains(item.id), selection.count > 1 else { return [item.id] }
        return orderedIDs(selection, in: rows)
    }

    private func orderedIDs(_ ids: Set<String>, in rows: [SongRowItem]) -> [String] {
        rows.map(\.id).filter(ids.contains)
    }
}

struct SavedAlbumsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(library.savedAlbums) { MediaItemCard(item: $0) }
            }
            .padding(24)
        }
    }
}

struct SearchView: View {
    @Environment(Library.self) private var library
    @State private var query = ""
    @State private var songs: [Song] = []
    @State private var items: [MediaItem] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Songs, albums, artists", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                    if searching { ProgressView().controlSize(.small) }
                }
                .font(.title2)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 24)

                if !songs.isEmpty {
                    Text("Songs").font(.title2.bold()).padding(.horizontal, 24)
                    SongGrid(songs: Array(songs.prefix(16)))
                }
                if !items.isEmpty {
                    Text("Albums, artists and playlists").font(.title2.bold()).padding(.horizontal, 24)
                    Shelf { ForEach(items) { MediaItemCard(item: $0) } }
                }
            }
            .padding(.vertical, 20)
        }
        .onAppear { focused = true }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { songs = []; items = []; searching = false; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let result = await library.search(q)
            guard !Task.isCancelled else { return }
            songs = result.songs
            items = result.items
        }
    }
}
