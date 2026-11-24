import Foundation
import Testing
@testable import MusicSample
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The on-device model that sorts songs into regular, unplugged and altered, on
/// labelled titles. Calls the model directly (no disk cache). Reports accuracy and every
/// miss; fails only below 85%, since single answers can move between OS versions.
@Suite struct SongKindsEvalTests {
    static let labelled: [(title: String, artist: String, album: String, kind: SongKind)] = [
        // Unplugged: no drums.
        ("Blinding Lights (Piano Cover)", "Piano Dreamers", "Piano Covers Vol. 3", .unplugged),
        ("Unravel - Pf solo", "Animenz", "Unravel", .unplugged),
        ("Gurenge [Piano]", "Theishter", "Anime Piano", .unplugged),
        ("Someone Like You (Acoustic)", "Adele", "Someone Like You", .unplugged),
        ("Wonderwall - Guitar Cover", "Fingerstyle Sessions", "Covers", .unplugged),
        ("Merry-Go-Round of Life (Orchestral Version)", "Studio Orchestra", "Ghibli Symphonic", .unplugged),
        ("Clair de Lune", "Claude Debussy", "Suite bergamasque", .unplugged),
        ("Bohemian Rhapsody (String Quartet)", "Vitamin String Quartet", "VSQ Performs Queen", .unplugged),
        ("Megalovania (Music Box)", "Music Box Lullabies", "Game Lullabies", .unplugged),
        ("Pentatonix - Hallelujah (A Cappella)", "Pentatonix", "A Pentatonix Christmas", .unplugged),
        ("An Ending (Ascent)", "Brian Eno", "Apollo", .unplugged),
        ("Kataomoi (Piano Arrangement)", "Aimer", "Piano Collection", .unplugged),
        // Altered: stretched edits.
        ("Snowfall (Slowed + Reverb)", "Øneheart", "Snowfall", .altered),
        ("Die For You - slowed", "The Weeknd", "Slowed Hits", .altered),
        ("Bad Apple!! (Nightcore)", "Nightcore Nation", "Nightcore", .altered),
        ("Metamorphosis (Sped Up)", "INTERWORLD", "Metamorphosis", .altered),
        ("Blinding Lights 8D Audio", "8D Tunes", "8D", .altered),
        ("Murder In My Mind (Super Slowed)", "Kordhell", "Phonk Slowed", .altered),
        // Regular: drums, including the near misses.
        ("Blinding Lights", "The Weeknd", "After Hours", .regular),
        ("Levels (Skrillex Remix)", "Avicii", "Levels", .regular),
        ("Lofi Study Beat", "Lofi Girl", "Chill Beats", .regular),
        ("Instrumental", "Nujabes", "Modal Soul", .regular),
        ("Midnight City", "M83", "Hurry Up, We're Dreaming", .regular),
        ("Sandstorm", "Darude", "Before the Storm", .regular),
        ("Murder In My Mind", "Kordhell", "Murder In My Mind", .regular),
        ("Take On Me (2017 Acoustic)", "a-ha", "MTV Unplugged", .unplugged),
        ("Strobe (Radio Edit)", "deadmau5", "For Lack of a Better Name", .regular),
        ("Gurenge", "LiSA", "Gurenge", .regular),
        ("Piano Man", "Billy Joel", "Piano Man", .regular),
        ("Reverb", "Fake Band", "Echoes", .regular),
        ("Ocean Eyes (Live)", "Billie Eilish", "Live at Third Man Records", .regular),
    ]

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(5)))
    func modelSortsLabelledTitles() async {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return }
        var confusion: [SongKind: [SongKind: Int]] = [:]
        var misses: [String] = []
        var noAnswer = 0
        for item in Self.labelled {
            let song = Song(id: "test-\(item.title.hashValue)", title: item.title, artist: item.artist, album: item.album, duration: 200)
            guard let kind = await SongKinds.judged(song) else { noAnswer += 1; misses.append("\(item.title): no answer"); continue }
            confusion[item.kind, default: [:]][kind, default: 0] += 1
            if kind != item.kind { misses.append("\(item.title): \(kind.rawValue), expected \(item.kind.rawValue)") }
        }
        let right = Self.labelled.count - misses.count
        let kinds: [SongKind] = [.regular, .unplugged, .altered]
        let table = kinds.map { truth in
            "  \(truth.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) -> " +
                kinds.map { "\($0.rawValue) \(confusion[truth]?[$0] ?? 0)" }.joined(separator: ", ")
        }.joined(separator: "\n")
        print("Song kinds: \(right)/\(Self.labelled.count) right, \(noAnswer) without answer\n\(table)\nMisses:\n  \(misses.joined(separator: "\n  "))")
        #expect(Double(right) >= Double(Self.labelled.count) * 0.85, "\(misses)")
        // The costly mistake is beat-matching an unplugged song or overlapping a regular
        // one as unplugged: count those on their own.
        #expect((confusion[.unplugged]?[.regular] ?? 0) <= 2, "unplugged songs judged regular: \(misses)")
        #endif
    }
}
