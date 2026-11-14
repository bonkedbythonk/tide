import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One YouTube Music search a mood asks for.
struct MoodSearch: Sendable {
    var query: String
    var kind: SearchKind
}

/// What a mood asks for: searches, and the artists it names ("covers from Animenz"),
/// whose own songs lead the queue.
struct MoodRequest: Sendable {
    var searches: [MoodSearch]
    var artists: [String] = []
}

/// Turns a request like "background music while I read" into YouTube Music searches.
/// Apple's on-device model plans the searches; YouTube supplies the songs, since the
/// model knows too little about music to name real tracks. Without Apple Intelligence
/// the request itself is searched as songs and playlists.
enum MoodPlanner {
    static func request(for prompt: String) async -> MoodRequest {
        #if canImport(FoundationModels)
        // Your own words stay one of the searches, so the mix never drifts far from them.
        if #available(macOS 26, *), var planned = await planned(prompt), !planned.searches.isEmpty {
            planned.searches.insert(MoodSearch(query: prompt, kind: .playlists), at: 0)
            return planned
        }
        #endif
        return MoodRequest(searches: [MoodSearch(query: prompt, kind: .songs), MoodSearch(query: prompt, kind: .playlists)])
    }

    /// Lowercase letters and digits only, to compare names loosely.
    static func squash(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// Whether `credit` names `artist` as whole words: "Animenz Piano Sheets" does,
    /// the look-alike channel "Animenzz" doesn't.
    static func credits(_ credit: String, _ artist: String) -> Bool {
        func words(_ s: String) -> String {
            " " + s.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: " ") + " "
        }
        return words(credit).contains(words(artist))
    }

    /// Your own songs (Home, history, likes) that fit the request, judged by title and
    /// artist in batches small enough for the on-device model. None without it.
    static func fitting(_ songs: [Song], prompt: String) async -> [Song] {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability {
            let batches = stride(from: 0, to: songs.count, by: 80).map { Array(songs[$0..<min($0 + 80, songs.count)]) }
            return await withTaskGroup(of: [Song].self) { group in
                for batch in batches { group.addTask { await picked(from: batch, prompt: prompt) } }
                var all: [Song] = []
                for await picks in group { all += picks }
                return all
            }
        }
        #endif
        return []
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func picked(from songs: [Song], prompt: String) async -> [Song] {
        let session = LanguageModelSession(instructions: """
            You pick songs from a numbered list that fit a listener's request, judging by \
            title and artist. Only pick songs you are fairly sure fit. Picking none is fine.
            """)
        let list = songs.enumerated().map { "\($0.offset + 1). \($0.element.title) - \($0.element.artist)" }
        let ask = "Request: \(prompt)\n\nSongs:\n" + list.joined(separator: "\n")
        guard let picks = try? await session.respond(to: ask, generating: MoodPicks.self).content.numbers else { return [] }
        return Set(picks).sorted().compactMap { songs.indices.contains($0 - 1) ? songs[$0 - 1] : nil }
    }

    @available(macOS 26, *)
    private static func planned(_ prompt: String) async -> MoodRequest? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn a listener's request into YouTube Music searches that together make a \
            long playlist matching it. Write short searches the way people type them \
            (genres, moods, artists, eras, "covers", "piano", "playlist"). Vary them so the \
            results don't all sound the same, but every search must fit the request. Use \
            "playlists" for broad styles and classics, "videos" for covers and fan \
            arrangements, "songs" for everything else. Never repeat a word within a search.

            Example request: chill music for coding
            Searches: lofi hip hop (playlists), synthwave instrumental (songs), \
            chillhop beats (songs), downtempo electronic (playlists), Nujabes (songs)
            """)
        guard let plan = try? await session.respond(to: prompt, generating: MoodPlan.self).content else { return nil }
        var seen = Set<String>()
        // Only artists really in the request: the model sometimes adds ones it thinks fit.
        let words = squash(prompt)
        let artists = plan.namedArtists.filter { !squash($0).isEmpty && words.contains(squash($0)) }
        let searches: [MoodSearch] = plan.searches.compactMap { s in
            // The model sometimes copies the example's "(songs)" into the search.
            let query = s.query.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            guard !query.isEmpty, seen.insert(query.lowercased()).inserted else { return nil }
            let kind: SearchKind = switch s.kind {
            case .songs: .songs
            case .videos: .videos
            case .playlists: .playlists
            }
            return MoodSearch(query: query, kind: kind)
        }
        return MoodRequest(searches: searches, artists: artists)
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct MoodPlan {
    @Guide(description: "Artists, bands or YouTube channels the request mentions by name. Empty if it names none.")
    var namedArtists: [String]
    @Guide(description: "YouTube Music searches for this request", .count(4...6))
    var searches: [PlannedSearch]
}

@available(macOS 26, *)
@Generable
struct MoodPicks {
    @Guide(description: "List numbers of the songs that fit the request", .maximumCount(25))
    var numbers: [Int]
}

@available(macOS 26, *)
@Generable
struct PlannedSearch {
    @Guide(description: "A search of 2 to 6 words")
    var query: String
    var kind: PlannedKind
}

@available(macOS 26, *)
@Generable
enum PlannedKind {
    case songs, videos, playlists
}
#endif
