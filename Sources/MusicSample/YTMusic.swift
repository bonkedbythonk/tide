import CryptoKit
import Foundation
import WebKit

typealias JSON = [String: Any]

enum YTError: LocalizedError {
    case signedOut
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Not signed in"
        case .http(let code): "YouTube Music returned HTTP \(code)"
        }
    }
}

/// Talks to YouTube Music's internal API (InnerTube), signed in with the cookies
/// from the sign-in window. Same requests the music.youtube.com website makes.
final class YTClient {
    static let origin = "https://music.youtube.com"
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private var cookieHeader = ""
    private var sapisid = ""
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    /// Picks up the session from the sign-in window's cookie store. False when signed out.
    @MainActor
    func loadCookies() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") }
        guard let sap = cookies.first(where: { $0.name == "SAPISID" })
            ?? cookies.first(where: { $0.name == "__Secure-3PAPISID" }) else { return false }
        sapisid = sap.value
        cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return true
    }

    /// Your sign-in for yt-dlp, which YouTube needs once it starts asking "are you a
    /// bot". Written in the Netscape format yt-dlp reads, readable only by you.
    @MainActor
    static func writeCookieFile() async -> URL? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com") }
        guard !cookies.isEmpty else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("cookies.txt")
        var lines = ["# Netscape HTTP Cookie File"]
        for c in cookies {
            let domain = c.domain.hasPrefix(".") ? c.domain : c.domain
            lines.append([
                domain, domain.hasPrefix(".") ? "TRUE" : "FALSE", c.path, c.isSecure ? "TRUE" : "FALSE",
                String(Int(c.expiresDate?.timeIntervalSince1970 ?? 0)), c.name, c.value,
            ].joined(separator: "\t"))
        }
        FileManager.default.createFile(atPath: file.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        return file
    }

    @MainActor
    static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let cookieFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicApp/cookies.txt")
        try? FileManager.default.removeItem(at: cookieFile)
        StreamResolver.cookieFile = nil
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    private var clientVersion: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return "1.\(f.string(from: .now.addingTimeInterval(-86_400))).01.00"
    }

    private var authorization: String {
        let ts = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(Self.origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }

    func call(_ endpoint: String, _ body: JSON = [:], query: [URLQueryItem] = []) async throws -> JSON {
        guard !sapisid.isEmpty else { throw YTError.signedOut }
        var url = URLComponents(string: "\(Self.origin)/youtubei/v1/\(endpoint)")!
        url.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")] + query
        var req = URLRequest(url: url.url!)
        req.httpMethod = "POST"
        var payload = body
        payload["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": "en"]]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.origin, forHTTPHeaderField: "Origin")
        req.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        req.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw YTError.http(status) }
        return try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
    }

    func browse(_ id: String) async throws -> JSON { try await call("browse", ["browseId": id]) }

    /// Puts a song in your YouTube history, which is what Home's "Listen again" and
    /// your recommendations are built from. Streams played through yt-dlp aren't
    /// counted, so this sends the play report YouTube Music's own player sends.
    func addToHistory(_ videoId: String) async {
        guard let player = try? await call("player", ["videoId": videoId]),
              let base = YTParse.dig(player, "playbackTracking", "videostatsPlaybackUrl", "baseUrl") as? String,
              var url = URLComponents(string: base) else { return }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let cpn = String((0..<16).map { _ in letters.randomElement()! })
        url.queryItems = (url.queryItems ?? []) + [
            URLQueryItem(name: "ver", value: "2"), URLQueryItem(name: "c", value: "WEB_REMIX"),
            URLQueryItem(name: "cpn", value: cpn),
        ]
        guard let target = url.url else { return }
        var req = URLRequest(url: target)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        _ = try? await session.data(for: req)
    }

    /// Next page of a list. Home uses the old query-string style, lists the body style.
    func more(_ token: String, homeStyle: Bool = false) async throws -> JSON {
        if homeStyle {
            return try await call("browse", query: [
                URLQueryItem(name: "ctoken", value: token),
                URLQueryItem(name: "continuation", value: token),
                URLQueryItem(name: "type", value: "next"),
            ])
        }
        return try await call("browse", ["continuation": token])
    }

    /// YouTube Music's radio for a song: the songs its Autoplay would queue after it.
    func radio(_ videoId: String) async throws -> JSON {
        try await call("next", ["videoId": videoId, "playlistId": "RDAMVM" + videoId, "isAudioOnly": true])
    }

    /// `params` picks one kind of result (see `SearchKind`); about 20 come back
    /// instead of the 3 or so per kind of a plain search.
    func search(_ query: String, params: String) async throws -> JSON {
        try await call("search", ["query": query, "params": params])
    }
}

/// YouTube Music's search filters, as the web app sends them.
enum SearchKind: String, CaseIterable {
    case songs = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    case videos = "EgWKAQIQAWoMEA4QChADEAQQCRAF"
    case artists = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
    case albums = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
    case playlists = "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU="

    var title: String {
        switch self {
        case .songs: "Songs"
        case .videos: "Videos"
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        }
    }
}

/// Pulls songs, cards and shelves out of InnerTube responses. Searches by renderer name
/// instead of fixed paths, so small layout changes on Google's side don't break it.
enum YTParse {
    static func findAll(_ key: String, in obj: Any) -> [JSON] {
        var out: [JSON] = []
        func walk(_ o: Any) {
            if let d = o as? JSON {
                if let hit = d[key] as? JSON { out.append(hit); return }
                d.values.forEach(walk)
            } else if let a = o as? [Any] {
                a.forEach(walk)
            }
        }
        walk(obj)
        return out
    }

    static func first(_ key: String, in obj: Any?) -> Any? {
        guard let obj else { return nil }
        if let d = obj as? JSON {
            if let v = d[key] { return v }
            for v in d.values { if let hit = first(key, in: v) { return hit } }
        } else if let a = obj as? [Any] {
            for v in a { if let hit = first(key, in: v) { return hit } }
        }
        return nil
    }

    static func dig(_ obj: Any?, _ path: String...) -> Any? {
        path.reduce(obj) { ($0 as? JSON)?[$1] }
    }

    static func runs(_ obj: Any?) -> [JSON] { (obj as? JSON)?["runs"] as? [JSON] ?? [] }

    static func text(_ obj: Any?) -> String {
        if let simple = (obj as? JSON)?["simpleText"] as? String { return simple }
        return runs(obj).compactMap { $0["text"] as? String }.joined()
    }

    /// Largest thumbnail, with Google's size suffix bumped so covers stay sharp.
    static func thumbnail(_ obj: Any?) -> (url: URL?, wide: Bool) {
        guard let list = first("thumbnails", in: obj) as? [JSON], let last = list.last,
              var url = last["url"] as? String else { return (nil, false) }
        if url.hasPrefix("//") { url = "https:" + url }
        if let r = url.range(of: #"w\d+-h\d+"#, options: .regularExpression) {
            url.replaceSubrange(r, with: "w544-h544")
        }
        let w = last["width"] as? Double ?? 1
        let h = last["height"] as? Double ?? 1
        return (URL(string: url), w > h * 1.2)
    }

    private static func pageType(_ run: JSON) -> String? {
        dig(run, "navigationEndpoint", "browseEndpoint", "browseEndpointContextSupportedConfigs",
            "browseEndpointContextMusicConfig", "pageType") as? String
    }

    private static let typeWords: Set<String> = ["Song", "Video", "Episode", "Single", "EP", "Album", "Playlist"]

    private static func seconds(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2, parts.count == s.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// One row of a song list (musicResponsiveListItemRenderer).
    static func song(_ r: JSON) -> Song? {
        guard let videoId = (dig(r, "playlistItemData", "videoId") as? String)
            ?? (first("videoId", in: r["overlay"]) as? String) else { return nil }
        let columns = (r["flexColumns"] as? [JSON] ?? []).map {
            $0["musicResponsiveListItemFlexColumnRenderer"] as? JSON ?? [:]
        }
        let title = text(columns.first?["text"])
        guard !title.isEmpty else { return nil }

        // Each column reads like "Song • Artist, Other & Third • Album • 3:45": split on " • "
        // and classify each segment as a whole, so unlinked featured artists aren't lost.
        var artist = ""
        var artistID: String?
        var plain: [String] = []
        var album = ""
        var albumID: String?
        var duration: TimeInterval = 0
        for column in columns.dropFirst() {
            var segments: [[JSON]] = [[]]
            for run in runs(column["text"]) {
                if run["text"] as? String == " • " { segments.append([]) } else { segments[segments.count - 1].append(run) }
            }
            for segment in segments where !segment.isEmpty {
                let t = segment.compactMap { $0["text"] as? String }.joined()
                let types = segment.compactMap(pageType)
                if let albumRun = segment.first(where: { pageType($0) == "MUSIC_PAGE_TYPE_ALBUM" }) {
                    album = t
                    albumID = dig(albumRun, "navigationEndpoint", "browseEndpoint", "browseId") as? String
                } else if let s = seconds(t) {
                    duration = s
                } else if types.contains("MUSIC_PAGE_TYPE_ARTIST") || types.contains("MUSIC_PAGE_TYPE_USER_CHANNEL") {
                    if artist.isEmpty {
                        artist = t
                        artistID = segment.lazy.compactMap {
                            dig($0, "navigationEndpoint", "browseEndpoint", "browseId") as? String
                        }.first
                    }
                } else if !typeWords.contains(t), !t.contains(" plays"), !t.contains(" views") {
                    plain.append(t)
                }
            }
        }
        if artist.isEmpty { artist = plain.first ?? "" }
        // Some search rows only name the artist in the play button's label: "Play <title> - <artist>".
        if artist.isEmpty, let label = first("label", in: r["overlay"]) as? String,
           let range = label.range(of: "\(title) - ") {
            artist = String(label[range.upperBound...])
        }
        if let fixed = (r["fixedColumns"] as? [JSON])?.first,
           let s = seconds(text(dig(fixed, "musicResponsiveListItemFixedColumnRenderer", "text"))) {
            duration = s
        }
        return Song(id: videoId, title: title, artist: artist, album: album, albumID: albumID,
                    artistID: artistID, duration: duration, artwork: thumbnail(r["thumbnail"]).url)
    }

    /// Songs of a radio queue (playlistPanelVideoRenderer), from the `next` endpoint.
    static func radio(_ json: JSON) -> [Song] {
        findAll("playlistPanelVideoRenderer", in: json).compactMap { r in
            guard let id = r["videoId"] as? String else { return nil }
            let title = text(r["title"])
            guard !title.isEmpty else { return nil }
            let byline = runs(r["longBylineText"])
            let artistRun = byline.first { pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" } ?? byline.first
            let albumRun = byline.first { pageType($0) == "MUSIC_PAGE_TYPE_ALBUM" }
            func browseID(_ run: JSON?) -> String? { run.flatMap { dig($0, "navigationEndpoint", "browseEndpoint", "browseId") as? String } }
            return Song(id: id, title: title, artist: artistRun?["text"] as? String ?? "",
                        album: albumRun?["text"] as? String ?? "", albumID: browseID(albumRun),
                        artistID: browseID(artistRun), duration: seconds(text(r["lengthText"])) ?? 0,
                        artwork: thumbnail(r["thumbnail"]).url)
        }
    }

    /// A card (musicTwoRowItemRenderer): album, playlist, mix, artist or a single video.
    static func card(_ r: JSON) -> ShelfItem? {
        let title = text(r["title"])
        let subtitleRuns = runs(r["subtitle"])
        let subtitle = text(r["subtitle"])
        let thumb = thumbnail(r["thumbnailRenderer"])
        guard !title.isEmpty else { return nil }

        if let browse = dig(r, "navigationEndpoint", "browseEndpoint") as? JSON,
           let id = browse["browseId"] as? String {
            let type = dig(browse, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") as? String
            let kind: MediaItem.Kind = switch type {
            case "MUSIC_PAGE_TYPE_ALBUM": .album
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL": .artist
            case "MUSIC_PAGE_TYPE_PLAYLIST": id.hasPrefix("VLRD") ? .mix : .playlist
            default: .other
            }
            return .media(MediaItem(id: id, title: title, subtitle: subtitle, artwork: thumb.url, kind: kind))
        }
        if let videoId = dig(r, "navigationEndpoint", "watchEndpoint", "videoId") as? String {
            let artistRun = subtitleRuns.first { pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" }
            let song = Song(id: videoId, title: title, artist: artistRun?["text"] as? String ?? subtitle, album: "", albumID: nil,
                            artistID: artistRun.flatMap { dig($0, "navigationEndpoint", "browseEndpoint", "browseId") as? String },
                            duration: 0, artwork: thumb.url)
            return .song(song, video: thumb.wide)
        }
        if let playlistId = dig(r, "navigationEndpoint", "watchPlaylistEndpoint", "playlistId") as? String {
            return .media(MediaItem(id: "VL" + playlistId, title: title, subtitle: subtitle, artwork: thumb.url, kind: .mix))
        }
        return nil
    }

    static func shelves(_ json: JSON) -> [HomeShelf] {
        let shelves = findAll("musicCarouselShelfRenderer", in: json)
            + findAll("musicImmersiveCarouselShelfRenderer", in: json)
        return shelves.compactMap { shelf in
            let title = text(first("title", in: shelf["header"]))
            let items: [ShelfItem] = (shelf["contents"] as? [JSON] ?? []).compactMap { item in
                if let row = item["musicResponsiveListItemRenderer"] as? JSON {
                    return song(row).map { .song($0, video: false) }
                }
                if let twoRow = item["musicTwoRowItemRenderer"] as? JSON { return card(twoRow) }
                return nil
            }
            return title.isEmpty || items.isEmpty ? nil : HomeShelf(title: title, items: items)
        }
    }

    static func cards(_ json: JSON) -> [MediaItem] {
        findAll("musicTwoRowItemRenderer", in: json).compactMap {
            if case .media(let m) = card($0) { m } else { nil }
        }
    }

    static func songs(_ json: JSON) -> [Song] {
        findAll("musicResponsiveListItemRenderer", in: json).compactMap(song)
    }

    static func continuation(_ json: JSON) -> String? {
        if let token = dig(first("continuationCommand", in: json), "token") as? String { return token }
        return dig(first("nextContinuationData", in: json), "continuation") as? String
    }

    /// A page's own song list, kept apart from the "Suggestions" YouTube shows under
    /// a playlist. `more` pages through the list itself; `suggestions` fetches the
    /// section after it, where the suggested songs live.
    struct ParsedPage {
        var data: PageData
        var more: String?
        var suggestions: String?
    }

    private static func isSuggestionShelf(_ shelf: JSON) -> Bool {
        let title = text(first("title", in: shelf["header"]) ?? shelf["title"]).lowercased()
        return title.contains("suggest") || title.contains("recommend")
    }

    static func page(_ json: JSON, id: String) -> ParsedPage {
        let header = (first("musicResponsiveHeaderRenderer", in: json)
            ?? first("musicDetailHeaderRenderer", in: json)
            ?? first("musicImmersiveHeaderRenderer", in: json)
            ?? first("musicVisualHeaderRenderer", in: json)) as? JSON ?? [:]
        let title = text(header["title"])
        let strap = text(header["straplineTextOne"])
        let subtitle = strap.isEmpty ? text(header["subtitle"]) : strap
        let art = thumbnail(header["thumbnail"] ?? header["foregroundThumbnail"]).url
        let mainShelf = findAll("musicPlaylistShelfRenderer", in: json).first
            ?? findAll("musicShelfRenderer", in: json).first { !isSuggestionShelf($0) }
        let suggestionShelf = findAll("musicShelfRenderer", in: json).first(where: isSuggestionShelf)
        var list = mainShelf.map(songs) ?? []
        // Album tracks come without cover or album name; fill them from the header.
        if id.hasPrefix("MPRE") {
            list = list.map { s in
                var s = s
                if s.artwork == nil { s.artwork = art }
                if s.album.isEmpty { s.album = title; s.albumID = id }
                return s
            }
        }
        var data = PageData(id: id, title: title, subtitle: subtitle, artwork: art, songs: list)
        data.suggestions = suggestionShelf.map(songs)
        if id.hasPrefix("UC") {
            data.shelves = shelves(json)
            data.allSongsID = mainShelf.flatMap { dig($0, "bottomEndpoint", "browseEndpoint", "browseId") as? String }
        }
        // Dictionary order is random, so pick the section list by its continuation, not position.
        let sectionList = findAll("sectionListRenderer", in: json).first { $0["continuations"] != nil }
        return ParsedPage(
            data: data,
            more: mainShelf.flatMap(continuation),
            suggestions: sectionList.flatMap { continuation(["c": $0["continuations"] ?? []]) }
        )
    }

    /// Search results: songs plus albums, artists and playlists.
    static func search(_ json: JSON) -> (songs: [Song], items: [MediaItem]) {
        var songs: [Song] = []
        var items: [MediaItem] = []
        for row in findAll("musicResponsiveListItemRenderer", in: json) {
            if let s = song(row) {
                songs.append(s)
            } else if let browse = dig(row, "navigationEndpoint", "browseEndpoint") as? JSON,
                      let id = browse["browseId"] as? String {
                let columns = (row["flexColumns"] as? [JSON] ?? []).map {
                    text(dig($0, "musicResponsiveListItemFlexColumnRenderer", "text"))
                }
                let type = dig(browse, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") as? String
                let kind: MediaItem.Kind = switch type {
                case "MUSIC_PAGE_TYPE_ALBUM": .album
                case "MUSIC_PAGE_TYPE_ARTIST": .artist
                case "MUSIC_PAGE_TYPE_PLAYLIST": .playlist
                default: .other
                }
                items.append(MediaItem(id: id, title: columns.first ?? "", subtitle: columns.dropFirst().joined(separator: " "),
                                       artwork: thumbnail(row["thumbnail"]).url, kind: kind))
            }
        }
        return (songs, items)
    }
}
