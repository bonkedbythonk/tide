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

/// Clean list: two lines per song, no lines between rows, hover controls.
/// Sort menu, Cmd-F filter, Cmd/Shift-click multi-select and drag.
struct SongListView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(Router.self) private var router
    let page: PageData
    let songs: [Song]
    let playlistID: String?

    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SongRowItem.number)]
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var appeared = false
    @State private var anchor: String?

    private var items: [SongRowItem] {
        var seen = Set<String>()
        let base = songs.filter { seen.insert($0.id).inserted }.enumerated().map { SongRowItem(number: $0 + 1, song: $1) }
        let query = Fuzzy.words(filter)
        let filtered = query.isEmpty ? base : base.filter {
            Fuzzy.score(query, in: "\($0.title) \($0.artist) \($0.album)") > 0
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
        // A List, not a lazy stack: it recycles rows like a table, so flinging through
        // hundreds of songs only updates rows that already exist.
        List {
            header(visibleSongs)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                row(item, in: rows, playlist: visibleSongs, suggested: suggestedSongs)
                    .modifier(PanelRow(index: index, count: rows.count, on: wallpaper.isActive))
            }
            if !suggestions.isEmpty {
                Text("Suggestions")
                    .font(.title3.bold())
                    .padding(.top, 22)
                    .padding(.bottom, 6)
                    .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 32))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                    row(item, in: suggestions, playlist: visibleSongs, suggested: suggestedSongs)
                        .modifier(PanelRow(index: index, count: suggestions.count, on: wallpaper.isActive))
                }
            }
            ForEach(page.shelves ?? []) { shelf in
                VStack(alignment: .leading, spacing: 12) {
                    Text(shelf.title).font(.title3.bold()).padding(.horizontal, 32)
                    ShelfContent(shelf: shelf)
                }
                .padding(.top, 22)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            // Quick: a long entrance read as the page loading slowly.
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
        // Resolve the first songs now, so Play starts without waiting on yt-dlp.
        .task(id: page.id) { songs.prefix(2).forEach { player.prefetch($0) } }
        .background {
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        }
    }

    private func row(_ item: SongRowItem, in list: [SongRowItem], playlist: [Song], suggested: [Song]) -> some View {
        let dragged = selection.contains(item.id) && selection.count > 1 ? orderedIDs(selection, in: list) : [item.id]
        return SongRow(item: item, selected: selection.contains(item.id),
                       addTo: item.isSuggestion ? playlistID : nil) {
            click(item, in: list, playlist: playlist, suggested: suggested)
        }
        .draggable(SongDrag.payload(dragged)) { DragPreview(songs: library.songs(dragged)) }
        .contextMenu {
            SongMenu(songs: library.songs(dragged), playlistID: item.isSuggestion ? nil : playlistID)
        }
    }

    /// Plain click plays; Cmd-click adds to the selection, Shift-click selects a range.
    private func click(_ item: SongRowItem, in list: [SongRowItem], playlist: [Song], suggested: [Song]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.remove(item.id) == nil { selection.insert(item.id) }
            anchor = item.id
        } else if mods.contains(.shift), let anchor, let from = list.firstIndex(where: { $0.id == anchor }),
                  let to = list.firstIndex(where: { $0.id == item.id }) {
            selection = Set(list[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [item.id]
            anchor = item.id
            play(item.song, playlist, suggested)
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
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    Button { player.playAll(visible, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    if let allSongsID = page.allSongsID {
                        Button { router.go(.page(allSongsID)) } label: {
                            Label("All Songs", systemImage: "music.note.list")
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    do {
                        Menu {
                            Picker("Sort by", selection: $sortOrder) {
                                Text("Playlist order").tag([KeyPathComparator(\SongRowItem.number)])
                                Text("Title").tag([KeyPathComparator(\SongRowItem.title)])
                                Text("Artist").tag([KeyPathComparator(\SongRowItem.artist)])
                                Text("Album").tag([KeyPathComparator(\SongRowItem.album)])
                                Text("Length").tag([KeyPathComparator(\SongRowItem.duration)])
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                        .menuStyle(.button)
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .fixedSize()
                    }
                    // The filter lives in the page now that there's no top bar (Cmd-F).
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter", text: $filter)
                            .textFieldStyle(.plain)
                            .focused($filterFocused)
                            .frame(width: 140)
                        if !filter.isEmpty {
                            Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
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
        .padding(.top, 30)  // room for the floating back/forward buttons
    }

    /// A suggestion plays among the suggestions, a playlist song among the playlist.
    private func play(_ song: Song, _ playlist: [Song], _ suggested: [Song]) {
        player.play(song, in: playlist.contains(song) ? playlist : suggested)
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
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var shelves: [HomeShelf] = []
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

                ForEach(shelves) { shelf in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(shelf.title).font(.title2.bold()).padding(.horizontal, 24)
                        ShelfContent(shelf: shelf)
                    }
                }
            }
            .padding(.top, 50)
            .padding(.bottom, 20)
        }
        // On appear and on every / or ⌘K. The short wait lets the field join the
        // window first; focusing it before that does nothing.
        .task(id: router.searchFocusRequest) {
            try? await Task.sleep(for: .milliseconds(30))
            focused = true
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { shelves = []; searching = false; return }
            // Five requests per search, so wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let result = await library.search(q)
            guard !Task.isCancelled else { return }
            shelves = result
        }
    }
}


/// Rounded pill buttons that read on both plain backgrounds and wallpaper glass:
/// solid accent for the main action, frosted for the rest.
struct PillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                if prominent {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// One song in a playlist: number (or a waveform while playing), cover, title over
/// artist, album and length. Like and + show on hover or when liked.
struct SongRow: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let item: SongRowItem
    let selected: Bool
    /// Set for a suggestion: one click adds it to this playlist.
    let addTo: String?
    let tap: () -> Void
    @State private var hovering = false
    @State private var pickerOpen = false

    var body: some View {
        let playing = player.current?.id == item.id
        HStack(spacing: 12) {
            Group {
                if playing {
                    Image(systemName: "waveform")
                        .foregroundStyle(.primary)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
                } else if item.isSuggestion {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                } else {
                    Text("\(item.number)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.callout)
            .frame(width: 26)
            Artwork(hue: item.song.hue, url: item.song.artwork, side: 40, radius: 6, symbol: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: playing ? .bold : .medium))
                    .foregroundStyle(item.isSuggestion && !playing ? Color.secondary : Color.primary)
                    .lineLimit(1)
                ArtistLink(song: item.song).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let addTo {
                Button {
                    withAnimation(.snappy) { library.add([item.id], to: addTo) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(prominent: false))
                .controlSize(.small)
                .help("Add to this playlist")
            } else {
                // Fixed slots so a liked heart doesn't shift when + appears on hover. The
                // controls (and +'s popover) only exist while needed: hundreds of idle
                // buttons made long playlists slow to scroll.
                HStack(spacing: 12) {
                    if hovering || pickerOpen || library.isLiked(item.id) {
                        LikeButton(songID: item.id)
                    } else {
                        Color.clear.frame(width: 16)
                    }
                    if hovering || pickerOpen {
                        AddToPlaylistButton(songIDs: [item.id], open: $pickerOpen)
                    } else {
                        Color.clear.frame(width: 16)
                    }
                }
                .frame(width: 48)
            }
            Text(item.album)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 210, alignment: .leading)
            Text(item.duration > 0 ? formatTime(item.duration) : "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            // Neutral washes, not the system blue, which clashed on the dark panel.
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
                selected ? Color.primary.opacity(0.16)
                    : playing ? Color.primary.opacity(0.10)
                    : hovering ? Color.primary.opacity(0.06) : .clear
            )
        }
        .contentShape(Rectangle())
        .stableHover { hovering = $0 }
        .task(id: hovering) {
            // Resting on a row for a moment starts resolving it (one hover tracker per row).
            guard hovering else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { player.prefetch(item.song) }
        }
        .onTapGesture(perform: tap)
    }
}

/// List-row chrome for the clean list: no separators, even spacing, and over a
/// wallpaper a dark panel (a tint, not a blur) whose first and last rows are rounded.
private struct PanelRow: ViewModifier {
    let index: Int
    let count: Int
    let on: Bool

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 1, leading: 24, bottom: 1, trailing: 24))
            .listRowSeparator(.hidden)
            .listRowBackground(
                Group {
                    if on {
                        UnevenRoundedRectangle(
                            topLeadingRadius: index == 0 ? 16 : 0, bottomLeadingRadius: index == count - 1 ? 16 : 0,
                            bottomTrailingRadius: index == count - 1 ? 16 : 0, topTrailingRadius: index == 0 ? 16 : 0,
                            style: .continuous
                        )
                        .fill(Color.black.opacity(0.42))
                        .padding(.horizontal, 14)
                    } else {
                        Color.clear
                    }
                }
            )
    }
}
