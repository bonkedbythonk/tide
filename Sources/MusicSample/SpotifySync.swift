import AppKit
import CryptoKit
import Network
import SwiftUI

/// Keeps chosen Spotify and YouTube Music playlists in step: a song added on one side
/// is added on the other. Removals are never copied. Signs in to Spotify with your own
/// Spotify app (developer.spotify.com), since Spotify lets a development app have only
/// 5 users. Runs on launch and every 30 minutes while Tide is open.
@MainActor @Observable final class SpotifySync {
    struct Pair: Codable, Hashable {
        var name: String
        /// A Spotify playlist id, `SpotifySync.liked`, or "new".
        var spotify: String
        /// A YouTube Music browse id ("VL…"), or "new".
        var youtube: String
    }

    struct Playlist: Hashable {
        let id: String
        let name: String
    }

    /// Songs already seen on each side of a pair, so each new one is copied only once.
    private struct Seen: Codable {
        var spotify: Set<String> = []
        var youtube: Set<String> = []
    }

    private struct Track {
        let id: String
        let title: String
        let artist: String
    }

    static let liked = "liked"
    static let redirect = "http://127.0.0.1:8888/callback"
    private static let scopes = "playlist-read-private playlist-modify-private playlist-modify-public "
        + "user-library-read user-library-modify"
    private static let stateFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicApp/spotify-sync.json")

    var clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID, forKey: "spotifyClientID") }
    }
    var pairs: [Pair] = {
        guard let data = UserDefaults.standard.data(forKey: "spotifyPairs") else { return [] }
        return (try? JSONDecoder().decode([Pair].self, from: data)) ?? []
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pairs), forKey: "spotifyPairs") }
    }
    var spotifyPlaylists: [Playlist] = []
    var connected = TokenFile.refreshToken != nil
    var busy = false
    var status = ""

    @ObservationIgnored weak var library: Library?
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing: Task<Void, Error>?

    /// Loads your Spotify playlists, syncs once, then every 30 minutes.
    func start(_ library: Library) async {
        self.library = library
        guard connected, !Demo.isOn else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        await loadPlaylists()
        await sync()
    }

    // MARK: Spotify sign-in

    /// Opens Spotify's sign-in in the browser and waits for it to come back to 127.0.0.1:8888.
    func connect() async {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        status = "Waiting for Spotify in your browser..."
        NSWorkspace.shared.open(url.url!)
        guard let code = await Loopback.code(state: state) else {
            status = "Spotify sign-in didn't finish"
            return
        }
        do {
            try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                             "client_id": id, "code_verifier": verifier])
            connected = true
            status = "Connected"
            if let library { await start(library) }
        } catch {
            status = "Spotify sign-in failed: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        TokenFile.refreshToken = nil
        accessToken = nil
        connected = false
        timer?.invalidate()
        spotifyPlaylists = []
        status = ""
    }

    private func token(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let access = json["access_token"] as? String else {
            throw SyncError(json["error_description"] as? String ?? "Spotify refused the sign-in", rejected: code == 400)
        }
        accessToken = access
        expiry = .now + TimeInterval(json["expires_in"] as? Int ?? 3600)
        if let refresh = json["refresh_token"] as? String { TokenFile.refreshToken = refresh }
    }

    private func refreshAccess() async throws {
        guard let refresh = TokenFile.refreshToken else { throw SyncError("Not connected to Spotify") }
        do {
            try await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        } catch let error as SyncError where error.rejected {
            // Only when Spotify itself says no; being offline keeps the sign-in.
            disconnect()
            throw SyncError("Spotify sign-in expired: connect again")
        }
    }

    // MARK: Spotify Web API

    private func api(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil) async throws -> JSON {
        if accessToken == nil || expiry < .now + 60 {
            // One refresh at a time: Spotify replaces the refresh token on each use, so
            // a second refresh with the old one is refused.
            if let refreshing {
                try await refreshing.value
            } else {
                let task = Task { try await self.refreshAccess() }
                refreshing = task
                defer { refreshing = nil }
                try await task.value
            }
        }
        var url = URLComponents(string: path.hasPrefix("https") ? path : "https://api.spotify.com/v1/" + path)!
        if !query.isEmpty {
            url.queryItems = (url.queryItems ?? []) + query
            url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var req = URLRequest(url: url.url!)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<6 {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429, attempt < 5 {
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                try await Task.sleep(for: .seconds(min(wait, 60)))
                continue
            }
            guard let code = http?.statusCode, (200..<300).contains(code) else {
                throw SyncError("Spotify returned HTTP \(http?.statusCode ?? 0)")
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
        }
        throw SyncError("Spotify is rate limiting, try again later")
    }

    /// Every page of a Spotify list, following `next`.
    private func pages(_ path: String, query: [URLQueryItem]) async throws -> [JSON] {
        var items: [JSON] = []
        var page = try await api("GET", path, query: query)
        while true {
            items += page["items"] as? [JSON] ?? []
            guard let next = page["next"] as? String else { return items }
            page = try await api("GET", next)
        }
    }

    /// Your own (and collaborative) Spotify playlists, with Liked Songs first.
    func loadPlaylists() async {
        do {
            let me = try await api("GET", "me")["id"] as? String
            let items = try await pages("me/playlists", query: [URLQueryItem(name: "limit", value: "50")])
            spotifyPlaylists = [Playlist(id: Self.liked, name: "Liked Songs")] + items.compactMap { p in
                let owner = (p["owner"] as? JSON)?["id"] as? String
                guard owner == me || p["collaborative"] as? Bool == true,
                      let id = p["id"] as? String, let name = p["name"] as? String else { return nil }
                return Playlist(id: id, name: name)
            }
            // A playlist you deleted on Spotify stops being synced.
            let ids = Set(spotifyPlaylists.map(\.id))
            pairs.removeAll { $0.spotify != "new" && !ids.contains($0.spotify) }
        } catch {
            status = error.localizedDescription
        }
    }

    private func spotifyTracks(_ id: String) async throws -> [Track] {
        let items = id == Self.liked
            ? try await pages("me/tracks", query: [URLQueryItem(name: "limit", value: "50")])
            : try await pages("playlists/\(id)/items", query: [URLQueryItem(name: "limit", value: "100"),
                                                                URLQueryItem(name: "additional_types", value: "track")])
        return items.compactMap { item in
            guard let t = (item["item"] ?? item["track"]) as? JSON, t["type"] as? String == "track",
                  let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            let artist = ((t["artists"] as? [JSON])?.first?["name"] as? String) ?? ""
            return Track(id: id, title: name, artist: artist)
        }
    }

    private func spotifyAdd(_ ids: [String], to id: String) async throws {
        let uris = ids.map { "spotify:track:\($0)" }
        if id == Self.liked {
            for start in stride(from: 0, to: uris.count, by: 40) {
                let chunk = uris[start..<min(start + 40, uris.count)].joined(separator: ",")
                _ = try await api("PUT", "me/library", query: [URLQueryItem(name: "uris", value: chunk)])
            }
        } else {
            for start in stride(from: 0, to: uris.count, by: 100) {
                _ = try await api("POST", "playlists/\(id)/items", body: ["uris": Array(uris[start..<min(start + 100, uris.count)])])
            }
        }
    }

    private func spotifyFind(_ title: String, _ artist: String) async throws -> String? {
        for q in ["track:\(title) artist:\(artist)", "\(title) \(artist)"] {
            let json = try await api("GET", "search", query: [URLQueryItem(name: "q", value: q),
                                                              URLQueryItem(name: "type", value: "track"),
                                                              URLQueryItem(name: "limit", value: "1")])
            if let id = ((json["tracks"] as? JSON)?["items"] as? [JSON])?.first?["id"] as? String { return id }
        }
        return nil
    }

    // MARK: YouTube Music side (through Tide's own sign-in)

    private func youtubeTracks(_ id: String, _ library: Library) async throws -> [Track] {
        guard let page = await library.reload(id) else { throw SyncError("Couldn't load the YouTube Music playlist") }
        return page.songs.map { Track(id: $0.id, title: $0.title, artist: Self.firstArtist($0.artist)) }
    }

    private func youtubeAdd(_ ids: [String], to id: String, _ library: Library) async throws {
        guard !ids.isEmpty else { return }
        if id == Library.likedID {
            for v in ids { try await library.client.rate("like", videoId: v) }
        } else {
            for start in stride(from: 0, to: ids.count, by: 100) {
                try await library.client.editPlaylist(Library.plainID(id), ids[start..<min(start + 100, ids.count)].map {
                    ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0]
                })
            }
        }
        _ = await library.reload(id)
    }

    private func youtubeFind(_ title: String, _ artist: String, _ library: Library) async throws -> String? {
        let json = try await library.client.search("\(title) \(artist)", params: SearchKind.songs.rawValue)
        return YTParse.search(json).songs.first?.id
    }

    // MARK: Syncing

    func sync() async {
        guard connected, !busy, let library, library.state == .ready, !pairs.isEmpty else { return }
        busy = true
        defer { busy = false }
        status = "Syncing..."
        await loadPlaylists()
        // Same for one deleted on YouTube Music (once Tide has a fresh playlist list).
        if !library.playlists.isEmpty {
            let ids = Set(library.playlists.map(\.id))
            pairs.removeAll { $0.youtube != "new" && $0.youtube != Library.likedID && !ids.contains($0.youtube) }
        }
        var seen = (try? Data(contentsOf: Self.stateFile)).flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:]
        var added = 0
        var unmatched = 0
        var failure: String?

        var createdOnSpotify = false
        for original in pairs {
            var pair = original
            status = "Syncing \(pair.name)..."
            do {
                if pair.spotify == "new" {
                    pair.spotify = try await api("POST", "me/playlists", body: ["name": pair.name, "description": "", "public": false])["id"] as? String ?? "new"
                    createdOnSpotify = true
                }
                if pair.youtube == "new" {
                    guard let id = await library.createPlaylist(pair.name) else { throw SyncError("Couldn't create \(pair.name)") }
                    pair.youtube = id
                }
                // Save created ids at once, so a failure below doesn't create them twice.
                if pair != original, let i = pairs.firstIndex(of: original) { pairs[i] = pair }

                let key = pair.spotify + "|" + pair.youtube
                var state = seen[key] ?? Seen()
                let onSpotify = try await spotifyTracks(pair.spotify)
                let onYouTube = try await youtubeTracks(pair.youtube, library)
                let spotifyKeys = Set(onSpotify.map { Self.key($0.title, $0.artist) })
                let youtubeKeys = Set(onYouTube.map { Self.key($0.title, $0.artist) })
                let spotifyIDs = Set(onSpotify.map(\.id))
                let youtubeIDs = Set(onYouTube.map(\.id))

                var toYouTube: [String] = []
                for t in onSpotify where !state.spotify.contains(t.id) && !youtubeKeys.contains(Self.key(t.title, t.artist)) {
                    if let v = try await youtubeFind(t.title, t.artist, library) {
                        if !youtubeIDs.contains(v), !toYouTube.contains(v) { toYouTube.append(v) }
                    } else {
                        unmatched += 1
                    }
                }
                var toSpotify: [String] = []
                for t in onYouTube where !state.youtube.contains(t.id) && !spotifyKeys.contains(Self.key(t.title, t.artist)) {
                    if let s = try await spotifyFind(t.title, t.artist) {
                        if !spotifyIDs.contains(s), !toSpotify.contains(s) { toSpotify.append(s) }
                    } else {
                        unmatched += 1
                    }
                }

                try await youtubeAdd(toYouTube, to: pair.youtube, library)
                try await spotifyAdd(toSpotify, to: pair.spotify)
                added += toYouTube.count + toSpotify.count
                state.spotify = spotifyIDs.union(toSpotify)
                state.youtube = youtubeIDs.union(toYouTube)
                seen[key] = state
                try? JSONEncoder().encode(seen).write(to: Self.stateFile, options: .atomic)
            } catch {
                failure = "\(pair.name): \(error.localizedDescription)"
            }
        }

        // New Spotify playlists show in the list, so their pairs can be changed or turned off.
        if createdOnSpotify { await loadPlaylists() }
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        var parts = ["Synced at \(time)", added == 1 ? "1 song added" : "\(added) songs added"]
        if unmatched > 0 { parts.append("\(unmatched) not found") }
        status = failure.map { "Sync failed for \($0)" } ?? parts.joined(separator: ", ")
    }

    /// The pair whose Spotify side is `id`, if that playlist is synced.
    func pair(spotify id: String) -> Pair? { pairs.first { $0.spotify == id } }

    func setSynced(_ playlist: Playlist, _ on: Bool) {
        if on {
            pairs.append(Pair(name: playlist.name, spotify: playlist.id, youtube: "new"))
        } else {
            pairs.removeAll { $0.spotify == playlist.id }
        }
    }

    /// A YouTube Music playlist synced to a new Spotify playlist.
    func isSynced(youtube id: String) -> Bool { pairs.contains { $0.youtube == id && $0.spotify == "new" } }

    func setSynced(youtube playlist: MediaItem, _ on: Bool) {
        if on {
            // A Spotify playlist of the same name is used instead of making a second one.
            let same = spotifyPlaylists.first {
                $0.name.lowercased() == playlist.title.lowercased() && pair(spotify: $0.id) == nil
            }
            pairs.append(Pair(name: playlist.title, spotify: same?.id ?? "new", youtube: playlist.id))
        } else {
            pairs.removeAll { $0.youtube == playlist.id && $0.spotify == "new" }
        }
    }

    func setPartner(spotify id: String, youtube target: String) {
        guard let i = pairs.firstIndex(where: { $0.spotify == id }) else { return }
        pairs[i].youtube = target
    }

    // MARK: Helpers

    /// The same song on both services, roughly: title without "(Remastered)", "feat." and
    /// such, plus the first artist.
    private static func key(_ title: String, _ artist: String) -> String {
        let t = title.lowercased().replacingOccurrences(
            of: #"\(.*?\)|\[.*?\]|- .*remaster.*|feat\..*"#, with: "", options: .regularExpression)
        func clean(_ s: String) -> String {
            s.filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
        }
        return clean(t) + "|" + clean(firstArtist(artist).lowercased())
    }

    private static func firstArtist(_ s: String) -> String {
        String(s.components(separatedBy: ", ").first?.components(separatedBy: " & ").first ?? s)
    }

    private static func randomString(_ count: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).map { _ in letters.randomElement()! })
    }
}

struct SyncError: LocalizedError {
    let message: String
    /// Spotify answered and refused the sign-in (not a network failure).
    var rejected = false
    init(_ message: String, rejected: Bool = false) {
        self.message = message
        self.rejected = rejected
    }
    var errorDescription: String? { message }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Catches Spotify's redirect after sign-in: a one-request web server on 127.0.0.1:8888.
private enum Loopback {
    static func code(state: String) async -> String? {
        await withCheckedContinuation { continuation in
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8888)
            guard let listener = try? NWListener(using: params) else { return continuation.resume(returning: nil) }
            var finished = false
            func finish(_ code: String?) {
                guard !finished else { return }
                finished = true
                listener.cancel()
                continuation.resume(returning: code)
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
                    let code = items.first { $0.name == "code" }?.value
                    let ok = code != nil && items.first { $0.name == "state" }?.value == state
                    let body = ok ? "Tide is connected to Spotify. You can close this tab."
                        : "Spotify sign-in didn't work. You can close this tab."
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n"
                        + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    if path.hasPrefix("/callback") { finish(ok ? code : nil) }
                }
            }
            listener.stateUpdateHandler = { if case .failed = $0 { finish(nil) } }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { finish(nil) }
        }
    }
}

/// The Spotify refresh token, in a file only you can read, like the YouTube cookies.
/// (The keychain would ask again after every update, since Tide isn't signed.)
private enum TokenFile {
    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicApp/spotify-token")

    static var refreshToken: String? {
        get { (try? String(contentsOf: file, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            try? FileManager.default.removeItem(at: file)
            guard let newValue else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data(newValue.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
    }
}
