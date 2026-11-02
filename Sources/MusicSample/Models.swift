import SwiftUI

struct Song: Identifiable, Hashable, Codable {
    /// YouTube videoId.
    let id: String
    let title: String
    let artist: String
    var album: String
    var albumID: String?
    let duration: TimeInterval
    var artwork: URL?

    var hue: Double { Double(id.stableHash % 1000) / 1000 }
    /// Fake playback needs a length even when YouTube didn't send one (Home items).
    var playDuration: TimeInterval { duration > 0 ? duration : 210 }
}

/// Anything that opens a page: playlist, album, artist, mix.
struct MediaItem: Identifiable, Hashable, Codable {
    enum Kind: Hashable, Codable { case playlist, album, artist, mix, other }

    /// browseId, e.g. "VLPL…", "MPREb_…", "UC…".
    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
    let kind: Kind

    var hue: Double { Double(id.stableHash % 1000) / 1000 }
}

enum ShelfItem: Identifiable, Hashable, Codable {
    case song(Song, video: Bool)
    case media(MediaItem)

    var id: String {
        switch self {
        case .song(let s, _): "s:" + s.id
        case .media(let m): "m:" + m.id
        }
    }
}

struct HomeShelf: Identifiable, Codable {
    let title: String
    let items: [ShelfItem]

    var id: String { title }
    var songs: [Song] {
        items.compactMap { if case .song(let s, _) = $0 { s } else { nil } }
    }
    /// Shelves like Quick picks: plain songs shown as a list grid.
    var isSongList: Bool {
        !items.isEmpty && items.allSatisfy { if case .song(_, false) = $0 { true } else { false } }
    }
    var isVideos: Bool {
        items.contains { if case .song(_, true) = $0 { true } else { false } }
    }
}

struct PageData: Codable {
    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
    var songs: [Song]
    /// YouTube's suggested songs for a playlist, shown separately, never mixed in.
    var suggestions: [Song]?
}

struct LyricLine: Hashable, Codable {
    let time: TimeInterval
    let text: String
}

enum Route: Hashable {
    case home, search, liked, savedAlbums
    case page(String)
}

enum PanelTab: Hashable {
    case queue, lyrics
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// SplitMix64, so placeholder content is the same on every launch.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension String {
    var stableHash: UInt64 { utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 } }
}

/// Song drags carry "songs:id1,id2" so drops can ignore unrelated text.
enum SongDrag {
    static func payload(_ ids: [String]) -> String { "songs:" + ids.joined(separator: ",") }
    static func ids(from items: [String]) -> [String] {
        items.flatMap { item -> [String] in
            guard item.hasPrefix("songs:") else { return [] }
            return item.dropFirst(6).split(separator: ",").map(String.init)
        }
    }
}

/// JSON snapshots on disk, so Home and playlists show instantly on launch while
/// fresh copies load in the background.
enum DiskCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MusicApp/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let queue = DispatchQueue(label: "disk cache", qos: .utility)

    private static func file(_ name: String) -> URL {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = file(name)
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }
}
