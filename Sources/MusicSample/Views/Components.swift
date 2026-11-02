import SwiftUI

/// Cover art from YouTube, with a gradient while it loads (or when there is none).
struct Artwork: View {
    let hue: Double
    var url: URL?
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 6
    var symbol: String? = "music.note"

    init(hue: Double, url: URL? = nil, side: CGFloat, radius: CGFloat = 6, symbol: String? = "music.note") {
        self.init(hue: hue, url: url, width: side, height: side, radius: radius, symbol: symbol)
    }

    init(hue: Double, url: URL? = nil, width: CGFloat, height: CGFloat, radius: CGFloat = 6, symbol: String? = "music.note") {
        self.hue = hue
        self.url = url
        self.width = width
        self.height = height
        self.radius = radius
        self.symbol = symbol
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.45, brightness: 0.9),
                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.5),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            if let url {
                CachedImage(url: url, maxPixelSize: max(width, height) * 2)
                    .frame(width: width, height: height)
                .clipShape(shape)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: min(width, height) * 0.32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: width, height: height)
    }
}

struct LikeButton: View {
    @Environment(Library.self) private var library
    let songID: String

    var body: some View {
        let liked = library.isLiked(songID)
        Button { library.toggleLike(songID) } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? Color.pink : Color.secondary)
                .symbolEffect(.bounce, value: liked)
        }
        .buttonStyle(.borderless)
        .help(liked ? "Remove from Liked Songs" : "Like")
    }
}

/// The "+" that replaces YouTube Music's three-dot > Add to playlist.
struct AddToPlaylistButton: View {
    let songIDs: [String]
    @Binding var open: Bool

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "plus.circle").foregroundStyle(Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Add to playlist")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PlaylistPicker(songIDs: songIDs) { open = false }
        }
    }
}

/// Self-contained version for places that always show the button.
struct StandaloneAddButton: View {
    let songIDs: [String]
    @State private var open = false

    var body: some View { AddToPlaylistButton(songIDs: songIDs, open: $open) }
}

struct PlaylistPicker: View {
    @Environment(Library.self) private var library
    let songIDs: [String]
    let done: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var filtered: [MediaItem] {
        let sorted = library.playlists.sorted { a, b in
            (a.id == library.lastUsedPlaylistID ? 0 : 1) < (b.id == library.lastUsedPlaylistID ? 0 : 1)
        }
        return query.isEmpty ? sorted : sorted.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find a playlist", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first = filtered.first { choose(first) } }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { p in
                        Button { choose(p) } label: {
                            HStack(spacing: 8) {
                                Artwork(hue: p.hue, url: p.artwork, side: 26, radius: 4, symbol: nil)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(p.title).lineLimit(1)
                                    if p.id == library.lastUsedPlaylistID {
                                        Text("Last used").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if library.contains(songIDs, in: p.id) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(HoverHighlight())
                    }
                }
            }
            .frame(height: min(CGFloat(filtered.count) * 36 + 4, 300))
        }
        .padding(10)
        .frame(width: 280)
        .onAppear { focused = true }
    }

    private func choose(_ p: MediaItem) {
        if library.contains(songIDs, in: p.id) {
            library.remove(songIDs, from: p.id)
        } else {
            library.add(songIDs, to: p.id)
        }
        done()
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .onHover { hovering = $0 }
    }
}

struct DragPreview: View {
    let songs: [Song]

    var body: some View {
        HStack(spacing: 8) {
            if let first = songs.first {
                Artwork(hue: first.hue, url: first.artwork, side: 30, radius: 4)
                Text(songs.count == 1 ? first.title : "\(songs.count) songs")
                    .font(.callout.weight(.medium))
            }
        }
        .padding(6)
        .padding(.trailing, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A song's artist name that opens the artist's page, underlined on hover.
/// Plain text when YouTube gave no artist link.
struct ArtistLink: View {
    @Environment(Router.self) private var router
    let song: Song
    @State private var hovering = false

    var body: some View {
        if let id = song.artistID {
            Text(song.artist)
                .underline(hovering)
                .onHover { hovering = $0 }
                .onTapGesture { router.go(.page(id)) }
                .help("Go to \(song.artist)")
        } else {
            Text(song.artist)
        }
    }
}

/// Right-click menu shared by every song row.
struct SongMenu: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    let songs: [Song]
    var playlistID: String?

    var body: some View {
        let ids = songs.map(\.id)
        Button("Play Next") { player.playNext(songs) }
        Button("Add to Queue") { player.addToQueue(songs) }
        Divider()
        Menu("Add to Playlist") {
            ForEach(library.playlists) { p in
                Button(p.title) { library.add(ids, to: p.id) }
            }
        }
        Button("Like") { library.like(ids) }
        if let playlistID {
            Button("Remove from This Playlist") { library.remove(ids, from: playlistID) }
        }
        if songs.count == 1, let song = songs.first, song.albumID != nil || song.artistID != nil {
            Divider()
            if let artistID = song.artistID { Button("Go to Artist") { router.go(.page(artistID)) } }
            if let albumID = song.albumID { Button("Go to Album") { router.go(.page(albumID)) } }
        }
    }
}

/// Compact song row used in Home grids and search results. Single click plays.
/// Hover-only controls are built only while hovered (or while their popover is open),
/// so a grid of hundreds of rows stays cheap to scroll.
struct SongTile: View {
    @Environment(Player.self) private var player
    let song: Song
    let context: [Song]
    @State private var hovering = false
    @State private var pickerOpen = false

    var body: some View {
        let isCurrent = player.current?.id == song.id
        HStack(spacing: 10) {
            ZStack {
                Artwork(hue: song.hue, url: song.artwork, side: 44, radius: 5)
                if isCurrent {
                    PlayingIndicator()
                } else if hovering {
                    RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                    Image(systemName: "play.fill").foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                Text(song.album.isEmpty ? song.artist : "\(song.artist) • \(song.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering || pickerOpen {
                LikeButton(songID: song.id)
                AddToPlaylistButton(songIDs: [song.id], open: $pickerOpen)
            }
        }
        .frame(height: 44)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .stableHover { hovering = $0 }
        .task(id: hovering) {
            // Resting on a row for a moment starts resolving it (your snappy plugin's idea).
            guard hovering else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { player.prefetch(song) }
        }
        .onTapGesture { player.play(song, in: context) }
        .draggable(SongDrag.payload([song.id])) { DragPreview(songs: [song]) }
        .contextMenu { SongMenu(songs: [song]) }
    }
}

struct SongGrid: View {
    let songs: [Song]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 6)], spacing: 2) {
            ForEach(songs) { SongTile(song: $0, context: songs) }
        }
        .padding(.horizontal, 18)
    }
}

struct MediaCard: View {
    let title: String
    let subtitle: String
    let hue: Double
    var artwork: URL?
    var width: CGFloat = 165
    var wide = false
    var round = false
    var symbol = "music.note"
    let open: () -> Void
    let play: (() -> Void)?
    var prefetch: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(hue: hue, url: artwork, width: width, height: wide ? width * 9 / 16 : width,
                        radius: round ? width / 2 : 8, symbol: symbol)
                    .scaleEffect(hovering ? 1.03 : 1)
                    .animation(.spring(duration: 0.25, bounce: 0.3), value: hovering)
                if hovering, let play {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .stableHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering, let prefetch else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { prefetch() }
        }
        .onTapGesture(perform: open)
    }
}

/// Horizontal row of cards. Swipe-to-go-back is paused while the pointer is over it.
struct Shelf<Content: View>: View {
    @Environment(Router.self) private var router
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) { content }
                .padding(.horizontal, 24)
        }
        .onHover { router.pointerOverShelf = $0 }
    }
}

/// Runs `action` once the pointer has rested on the view for a moment.
struct OnDwell: ViewModifier {
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .stableHover { hovering = $0 }
            .task(id: hovering) {
                guard hovering else { return }
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { action() }
            }
    }
}
