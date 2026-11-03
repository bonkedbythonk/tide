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
    @State private var confirmDelete = false

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
        // A lazy stack, not a List: the List measured every row as a page opened, which
        // froze Tide for seconds on long lists like Liked Songs and History.
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            header(visibleSongs)
            if page.id.hasPrefix("UC"), !rows.isEmpty {
                Text("Top songs").font(.title3.bold()).padding(.horizontal, 32).padding(.bottom, 10)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                row(item, in: rows, playlist: visibleSongs, suggested: suggestedSongs)
                    .modifier(PanelRow(index: index, count: rows.count, on: wallpaper.isActive))
            }
            if !suggestions.isEmpty {
                Text("Suggestions")
                    .font(.title3.bold())
                    .padding(.top, 22)
                    .padding(.bottom, 6)
                    .padding(.horizontal, 32)
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
            }
          }
          .padding(.bottom, 20)
        }
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
                // An artist page lists only their top songs, so a count would mislead.
                let isArtist = page.id.hasPrefix("UC")
                Text([page.subtitle, isArtist ? "" : "\(visible.count) songs",
                      !isArtist && minutes > 0 ? "\(minutes) min" : ""]
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
                    .buttonStyle(PillButtonStyle(prominent: false, active: player.shuffle))
                    if let allSongsID = page.allSongsID {
                        Button { router.go(.page(allSongsID)) } label: {
                            Label("All Songs", systemImage: "music.note.list")
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    if page.channelID != nil {
                        let on = page.subscribed ?? false
                        Button { library.toggleSubscribed(page.id) } label: {
                            Label(on ? "Subscribed" : "Subscribe", systemImage: on ? "checkmark" : "person.badge.plus")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    if page.saveID != nil, page.owned != true {
                        let on = page.saved ?? false
                        Button { library.toggleSaved(page.id) } label: {
                            Label(on ? "Saved" : "Save", systemImage: on ? "bookmark.fill" : "bookmark")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    if ["VL", "MPRE", "UC"].contains(where: page.id.hasPrefix) {
                        Menu {
                            Button("Copy Link") { library.copyLink(page.id) }
                            if page.owned == true, page.id != Library.likedID {
                                Divider()
                                Button("Rename…") {
                                    router.prompt = TextPrompt(title: "Rename Playlist", button: "Rename", text: page.title) {
                                        library.renamePlaylist(page.id, to: $0)
                                    }
                                }
                                Button("Delete Playlist…", role: .destructive) { confirmDelete = true }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .fixedSize()
                        .confirmationDialog("Delete \(page.title)?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) {
                                library.deletePlaylist(page.id)
                                router.goBack()
                            }
                        } message: {
                            Text("It's removed from your YouTube Music account.")
                        }
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

/// Your library: playlists, saved albums, artists you listen to, and songs you added.
struct LibraryView: View {
    enum Tab: Hashable { case playlists, albums, artists, songs }

    @Environment(Library.self) private var library
    @State private var tab = Tab.playlists

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.system(size: 34, weight: .bold))
                Spacer()
                PillSwitch(options: [("Playlists", .playlists), ("Albums", .albums), ("Artists", .artists), ("Songs", .songs)],
                           selection: $tab)
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 8)
            Group {
                if tab == .songs {
                    PageView(id: Library.librarySongsID)
                } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], alignment: .leading, spacing: 24) {
                        ForEach(tab == .playlists ? library.playlists : tab == .albums ? library.savedAlbums : library.libraryArtists) {
                            MediaItemCard(item: $0)
                        }
                    }
                    .padding(24)
                }
                }
            }
            .id(tab)
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
        .animation(.snappy(duration: 0.25), value: tab)
        .task(id: tab) { if tab == .artists, library.libraryArtists.isEmpty { await library.loadLibraryArtists() } }
    }
}

struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var shelves: [HomeShelf] = []
    @State private var searching = false
    @State private var suggestions: [String] = []
    /// The search last picked or submitted; suggestions stay hidden while it's in the field.
    @State private var chosen: String?
    @State private var recent = Prefs.strings("recentSearches")
    @FocusState private var focused: Bool

    /// YouTube's suggestions while typing (recent searches show on the page itself).
    private var hints: [String] {
        query.isEmpty || query == chosen ? [] : Array(suggestions.prefix(6))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Songs, albums, artists", text: $query)
                            .textFieldStyle(.plain)
                            .focused($focused)
                            .onSubmit { choose(query) }
                        if searching { ProgressView().controlSize(.small) }
                    }
                    .font(.title2)
                    .padding(12)
                    if focused, !hints.isEmpty {
                        Divider().padding(.horizontal, 12)
                        ForEach(hints, id: \.self) { hint in
                            Button { choose(hint) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    Text(hint)
                                    Spacer()
                                }
                                .padding(.vertical, 7)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .modifier(HoverHighlight())
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                .animation(.snappy(duration: 0.2), value: hints)
                .animation(.snappy(duration: 0.2), value: focused)
                .padding(.horizontal, 24)

                if query.isEmpty {
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Recent searches").font(.title2.bold())
                                Spacer()
                                Button("Clear") {
                                    withAnimation(.snappy) { recent = [] }
                                    Prefs.set(recent, "recentSearches")
                                }
                                .buttonStyle(PillButtonStyle(prominent: false))
                            }
                            .padding(.horizontal, 24)
                            ForEach(recent.prefix(8), id: \.self) { past in
                                Button { choose(past) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 20)
                                        Text(past)
                                        Spacer()
                                    }
                                    .padding(.vertical, 7)
                                    .padding(.horizontal, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .modifier(HoverHighlight())
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    // History lists a song each time it was played; show it once.
                    var seen = Set<String>()
                    let played = (library.pages[Library.historyID]?.songs ?? []).filter { seen.insert($0.id).inserted }
                    if !played.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recently played").font(.title2.bold()).padding(.horizontal, 24)
                            SongGrid(songs: Array(played.prefix(12)))
                        }
                    }
                }
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
        .task { _ = await library.page(Library.historyID) }
        .task(id: router.searchFocusRequest) {
            try? await Task.sleep(for: .milliseconds(30))
            focused = true
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { shelves = []; searching = false; suggestions = []; return }
            if query != chosen {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                suggestions = await library.searchSuggestions(q)
                guard !Task.isCancelled else { return }
            }
            // Five requests per search, so wait for a pause in typing (the suggestions
            // above already took part of it). A picked search goes at once.
            if query != chosen { try? await Task.sleep(for: .milliseconds(230)) }
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let result = await library.search(q)
            guard !Task.isCancelled else { return }
            shelves = result
        }
    }

    /// Searches for `text` and remembers it among your recent searches.
    private func choose(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        chosen = q
        query = q
        recent = [q] + recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }.prefix(9)
        Prefs.set(recent, "recentSearches")
    }
}


/// Rounded pill buttons that read on both plain backgrounds and wallpaper glass:
/// solid accent for the main action, frosted for the rest.
struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    /// Lit in the accent colour, for a mode that's on (Shuffle).
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, active: active)
    }
}

private struct PillBody: View {
    @Environment(\.barAccent) private var accent
    @Environment(\.accentFill) private var fill
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let active: Bool

    var body: some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : active ? accent : Color.primary)
            .background {
                if prominent {
                    Capsule().fill(fill)
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
                    if hovering || pickerOpen {
                        LikeButton(songID: item.id)
                    } else if library.isLiked(item.id) {
                        // A plain heart until hovered: on Liked Songs every row has one, and
                        // a real button in each made the page slow to open.
                        Image(systemName: "heart.fill").foregroundStyle(Color.pink).frame(width: 16)
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
        // One known height, so the list doesn't have to measure every row as it opens.
        .frame(height: 52)
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
            .padding(.vertical, 1)
            // Room inside the panel above the first row and below the last, so a
            // highlighted row doesn't touch its edge.
            .padding(.top, on && index == 0 ? 8 : 0)
            .padding(.bottom, on && index == count - 1 ? 8 : 0)
            .padding(.horizontal, 24)
            .background(
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
