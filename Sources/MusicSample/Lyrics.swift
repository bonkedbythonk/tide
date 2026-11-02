import Foundation

/// Lyrics from LRCLIB (the free lyrics database Pear's synced-lyrics plugin uses),
/// timed when LRCLIB has a synced version. Kept in memory and on disk.
@Observable final class LyricsStore {
    enum Result: Codable, Equatable {
        case synced([LyricLine])
        case plain(String)
        case instrumental
        case none
    }

    private(set) var results: [String: Result] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    func result(for songID: String) -> Result? { results[songID] }

    @MainActor
    func load(_ song: Song, duration: TimeInterval) async {
        guard results[song.id] == nil, !loading.contains(song.id) else { return }
        if Demo.isOn { results[song.id] = .synced(Demo.lyrics); return }
        if let cached = DiskCache.load(Result.self, "lyrics-" + song.id) {
            results[song.id] = cached
            return
        }
        loading.insert(song.id)
        defer { loading.remove(song.id) }
        guard let result = await Self.fetch(song, duration: duration) else { return }
        results[song.id] = result
        DiskCache.save(result, "lyrics-" + song.id)
    }

    private struct Entry: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    /// Nil when the request itself failed (so it is retried next time), `.none` when
    /// LRCLIB simply has nothing for the song.
    private static func fetch(_ song: Song, duration: TimeInterval) async -> Result? {
        var url = URLComponents(string: "https://lrclib.net/api/search")!
        url.queryItems = [
            URLQueryItem(name: "track_name", value: cleanTitle(song.title)),
            URLQueryItem(name: "artist_name", value: mainArtist(song.artist)),
        ]
        var request = URLRequest(url: url.url!)
        request.setValue("MusicApp (personal project)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }

        // Several uploads of one song differ in length; take the one closest to what's playing.
        let target = duration > 0 ? duration : song.duration
        let ranked = entries.sorted { a, b in
            guard target > 0 else { return false }
            return abs((a.duration ?? 0) - target) < abs((b.duration ?? 0) - target)
        }
        let usable = ranked.filter { target <= 0 || abs(($0.duration ?? target) - target) < 8 }
        if let synced = usable.first(where: { $0.syncedLyrics?.isEmpty == false })?.syncedLyrics {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = usable.first(where: { $0.plainLyrics?.isEmpty == false })?.plainLyrics {
            return .plain(plain)
        }
        if usable.contains(where: { $0.instrumental == true }) { return .instrumental }
        return Result.none
    }

    /// "[01:23.45] line" -> time and text. Empty timed lines are kept as gaps.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        lrc.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) else { return nil }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return LyricLine(time: minutes * 60 + seconds, text: text.isEmpty ? "…" : text)
        }
    }

    /// "Song (feat. X) [Official Video]" -> "Song"; LRCLIB matches on the bare title.
    private static func cleanTitle(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*(feat|ft\.|official|video|audio|lyric|mv|remaster)[^\)\]]*[\)\]]"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func mainArtist(_ artist: String) -> String {
        let first = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first ?? artist
        return first.replacingOccurrences(of: " - Topic", with: "").trimmingCharacters(in: .whitespaces)
    }
}
