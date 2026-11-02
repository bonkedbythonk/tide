import SwiftUI

struct Song: Identifiable, Hashable {
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
struct MediaItem: Identifiable, Hashable {
    enum Kind: Hashable { case playlist, album, artist, mix, other }

    /// browseId, e.g. "VLPL…", "MPREb_…", "UC…".
    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
    let kind: Kind

    var hue: Double { Double(id.stableHash % 1000) / 1000 }
}

enum ShelfItem: Identifiable, Hashable {
    case song(Song, video: Bool)
    case media(MediaItem)

    var id: String {
        switch self {
        case .song(let s, _): "s:" + s.id
        case .media(let m): "m:" + m.id
        }
    }
}

struct HomeShelf: Identifiable {
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

struct PageData {
    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
    var songs: [Song]
}

struct LyricLine: Hashable {
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

/// Placeholder lyrics until real ones are fetched.
enum FakeLyrics {
    static let phrases = [
        "I keep the porch light on for you", "Counting cars along the highway",
        "Your voice is a radio through the static", "We were young and running out of time",
        "Paint the ceiling gold tonight", "Every street still knows your name",
        "Hold on, the morning's coming", "Nothing left but the echo",
        "Dancing slow in an empty room", "Let the rain wash over us",
        "I hear the ocean in your sleep", "Burn it down and start again",
        "Follow the signal home", "Say it like you mean it this time",
        "Sunday mornings never felt so loud", "Under the neon we disappear",
    ]

    private static var cache: [String: [LyricLine]] = [:]

    static func lines(for song: Song) -> [LyricLine] {
        if let cached = cache[song.id] { return cached }
        var rng = SeededRNG(seed: song.id.stableHash)
        let verse = (0..<4).map { _ in phrases.randomElement(using: &rng)! }
        let chorus = (0..<4).map { _ in phrases.randomElement(using: &rng)! }
        let order = verse + chorus + verse.reversed() + chorus + chorus
        let length = song.playDuration
        var lines: [LyricLine] = []
        var t: TimeInterval = 6
        for text in order where t < length - 6 {
            lines.append(LyricLine(time: t, text: text))
            t += length / Double(order.count + 2)
        }
        cache[song.id] = lines
        return lines
    }
}
