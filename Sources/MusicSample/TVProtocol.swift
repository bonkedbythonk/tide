import Foundation

/// What Tide on the Mac and Tide on Apple TV send each other (shared by both targets).
enum TVProtocol {
    static let serviceType = "_tide._tcp"

    struct Hello: Codable {
        let name: String
    }

    struct LibraryList: Codable {
        let playlists: [MediaItem]
        let albums: [MediaItem]
    }

    /// The Mac's playback settings, which the TV follows.
    struct Settings: Codable {
        var smart: Bool
        var smooth: Bool
        var crossfade: Double
        var gapless: Bool
        var matchLoudness: Bool
    }

    /// The part of the Mac's TransitionPlan the TV plays (decoded from the same JSON).
    struct Mix: Codable {
        var outAt: TimeInterval
        var inAt: TimeInterval
        var fade: TimeInterval
        var onBeat: Bool
        var matched: Bool
        var speed: Double
        var incomingSpeed: Double
        var beat: TimeInterval
        var swapDelay: TimeInterval?
        var swapsBass: Bool
        var ringOut: TimeInterval
        var layered: Bool
    }

    /// Synced lines when LRCLIB has them, else plain text; both nil means no lyrics.
    struct Lyrics: Codable {
        var lines: [LyricLine]?
        var plain: String?
    }
}
