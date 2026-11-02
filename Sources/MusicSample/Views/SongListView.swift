import AppKit
import SwiftUI

/// Loads a playlist / album / mix / artist page, then shows it.
struct PageView: View {
    @Environment(Library.self) private var library
    let id: String
    var fallbackTitle = ""

    var body: some View {
        ZStack {
            if let page = library.pages[id] {
                SongListView(page: page, songs: library.songs(in: id),
                             playlistID: library.playlist(id) != nil ? id : nil)
                    .transition(.opacity.combined(with: .offset(y: 12)))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.1), value: library.pages[id] != nil)
        .task(id: id) { _ = await library.page(id) }
    }
}

struct SongRowItem: Identifiable {
    let number: Int
    let song: Song
    var isSuggestion = false
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
    @State private var appeared = false

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

    /// YouTube's suggestions, listed in their own section under the playlist.
    private var suggestionItems: [SongRowItem] {
        let inPlaylist = Set(songs.map(\.id))
        var seen = Set<String>()
        return (page.suggestions ?? [])
            .filter { !inPlaylist.contains($0.id) && seen.insert($0.id).inserted }
            .map { SongRowItem(number: 0, song: $0, isSuggestion: true) }
    }

    var body: some View {
        let rows = items
        let suggestions = suggestionItems
        let visibleSongs = rows.map(\.song)
        let suggestedSongs = suggestions.map(\.song)
        let allRows = rows + suggestions
        let currentID = player.current?.id
        VStack(spacing: 0) {
            header(visibleSongs)
            Table(of: SongRowItem.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("#", value: \.number) { item in
                    if currentID == item.id {
                        Image(systemName: "waveform")
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
                    } else if item.isSuggestion {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                    } else {
                        Text("\(item.number)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .width(38)
                TableColumn("Title", value: \.title) { item in
                    HStack(spacing: 8) {
                        Artwork(hue: item.song.hue, url: item.song.artwork, side: 28, radius: 4, symbol: nil)
                        Text(item.title)
                            .foregroundStyle(currentID == item.id ? Color.accentColor : item.isSuggestion ? Color.secondary : Color.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .modifier(OnDwell { player.prefetch(item.song) })
                }
                .width(min: 180, ideal: 300)
                TableColumn("Artist", value: \.artist)
                TableColumn("Album", value: \.album)
                TableColumn("") { item in
                    if item.isSuggestion, let playlistID {
                        // One click puts a suggestion into this playlist; no playlist picker.
                        Button {
                            withAnimation(.snappy) { library.add([item.id], to: playlistID) }
                        } label: {
                            Label("Add", systemImage: "plus")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Add to this playlist")
                    } else {
                        HStack(spacing: 10) {
                            LikeButton(songID: item.id)
                            StandaloneAddButton(songIDs: [item.id])
                        }
                    }
                }
                .width(64)
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
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { item in
                            TableRow(item).draggable(SongDrag.payload([item.id]))
                        }
                    } header: {
                        Text("Suggestions").font(.headline)
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                SongMenu(songs: library.songs(orderedIDs(ids, in: allRows)), playlistID: playlistID)
            } primaryAction: { ids in
                if let id = ids.first, let s = library.song(id) { play(s, visibleSongs, suggestedSongs) }
            }
            .onChange(of: selection) { _, new in
                guard new.count == 1, let id = new.first, let s = library.song(id),
                      NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) else { return }
                ClickToPlay.arm { play(s, visibleSongs, suggestedSongs) }
            }
            .scrollContentBackground(.hidden)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 28)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.18)) { appeared = true }
        }
        // Resolve the first songs now, so Play starts without waiting on yt-dlp.
        .task(id: page.id) { songs.prefix(2).forEach { player.prefetch($0) } }
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
                .scaleEffect(appeared ? 1 : 0.8, anchor: .bottomLeading)
                .opacity(appeared ? 1 : 0)
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
            .offset(x: appeared ? 0 : -16)
            .opacity(appeared ? 1 : 0)
            Spacer()
        }
        .padding(24)
    }

    /// A suggestion plays among the suggestions, a playlist song among the playlist.
    private func play(_ song: Song, _ playlist: [Song], _ suggested: [Song]) {
        player.play(song, in: playlist.contains(song) ? playlist : suggested)
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

