import Foundation

/// Made-up library for screenshots: launch with `--demo` (see `Scripts/screenshots.sh`).
/// Nothing is fetched or saved, and your own library, session and caches are left
/// alone. Covers come from `-demoCovers <folder>` (cover-0.jpg, cover-1.jpg, ...)
/// when given, otherwise the coloured placeholders.
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("--demo")

    private static let artists = [
        "Harbor Lights", "Mira Okafor", "The Slow Tides", "Juniper Vale", "Northbound",
        "Celeste Ray", "Paper Lanterns", "Ilse Marlow",
    ]
    private static let titles = [
        "Low Tide", "Glass Harbor", "Salt and Static", "Moonwake", "Undertow",
        "Paper Boats", "Coastline", "Driftwood Hymn", "Night Ferry", "Seafoam",
        "Lighthouse Keeper", "Brine", "Swell", "Morning Fog", "Blue Hour",
        "Shoreline", "Tidepool", "Anchor", "Weathervane", "Gulls",
        "Current", "Ebb", "Riptide", "Sandbar", "Halcyon",
        "Breakwater", "Estuary", "Lagoon", "Squall", "Still Water",
    ]
    private static let albums = ["Shorelines", "Night Ferry", "Blue Hour", "Halcyon Days", "Undertow EP"]

    static let lyrics: [LyricLine] = [
        "The harbour lights are low tonight", "and every boat is coming home",
        "I count the waves until the morning", "the tide will tell me where to go",
        "Salt on the window, static on the radio", "a song I almost know",
        "So let it pull me under", "let it carry me slow",
    ].enumerated().map { LyricLine(time: Double($0.offset) * 20 + 4, text: $0.element) }

    private static func cover(_ i: Int) -> URL? {
        guard let dir = UserDefaults.standard.string(forKey: "demoCovers") else { return nil }
        return URL(filePath: dir).appending(path: "cover-\(i % 24).jpg")
    }

    static let songs: [Song] = titles.enumerated().map { i, title in
        Song(id: "demo-song-\(i)", title: title, artist: artists[i % artists.count],
             album: albums[i % albums.count], albumID: "demo-album-\(i % albums.count)",
             duration: Double(150 + (i * 37) % 120), artwork: cover(i))
    }

    static let playlists: [MediaItem] = ["Late night", "Coffee", "Running", "Focus", "Rainy days", "Road trip"]
        .enumerated().map { MediaItem(id: "VLdemo-\($0.offset)", title: $0.element, subtitle: "Playlist", artwork: cover($0.offset + 6), kind: .playlist) }

    static let savedAlbums: [MediaItem] = albums.enumerated().map {
        MediaItem(id: "demo-album-\($0.offset)", title: $0.element, subtitle: artists[$0.offset], artwork: cover($0.offset + 12), kind: .album)
    }

    static var home: [HomeShelf] {
        [
            HomeShelf(title: "Listen again", items: songs.prefix(8).map { .song($0, video: false) }),
            HomeShelf(title: "Quick picks", items: songs.dropFirst(8).prefix(12).map { .song($0, video: false) }),
            HomeShelf(title: "Albums for you", items: savedAlbums.map { .media($0) }),
            HomeShelf(title: "Your playlists", items: playlists.map { .media($0) }),
        ]
    }

    static func page(_ item: MediaItem, offset: Int) -> PageData {
        let list = (0..<24).map { songs[($0 + offset) % songs.count] }
        return PageData(id: item.id, title: item.title, subtitle: item.subtitle, artwork: item.artwork, songs: list)
    }

    /// Opens on another screen for its screenshot: `-demoScreen playlist|nowplaying|settings`.
    static func open(_ screen: String?, router: Router) {
        switch screen {
        case "playlist": router.go(.page(playlists[0].id))
        case "nowplaying":
            router.showNowPlaying = true
            router.panelTab = .lyrics
        case "settings": router.go(.settings)
        default: break
        }
    }

    static var pages: [String: PageData] {
        var all: [String: PageData] = [:]
        let liked = MediaItem(id: Library.likedID, title: "Liked Music", subtitle: "Auto playlist", artwork: nil, kind: .playlist)
        for (i, item) in ([liked] + playlists + savedAlbums).enumerated() { all[item.id] = page(item, offset: i * 5) }
        return all
    }
}
