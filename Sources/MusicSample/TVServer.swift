import Foundation
import Network

/// Lets Tide on Apple TV browse your library and play through this Mac: the Mac
/// keeps the sign-in and yt-dlp, the TV asks over the local network. Off until
/// turned on in Settings; every request must carry the pairing code.
@MainActor @Observable final class TVServer {
    var enabled = UserDefaults.standard.bool(forKey: "tvServer") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "tvServer")
            update()
        }
    }
    private(set) var status = ""
    let code: String

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var lyrics: LyricsStore?
    @ObservationIgnored private var player: Player?
    @ObservationIgnored private var homeFetched = Date()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "tvCode") {
            code = saved
        } else {
            code = String(format: "%06d", Int.random(in: 0..<1_000_000))
            UserDefaults.standard.set(code, forKey: "tvCode")
        }
    }

    func attach(library: Library, lyrics: LyricsStore, player: Player) {
        self.library = library
        self.lyrics = lyrics
        self.player = player
        update()
    }

    private func update() {
        guard enabled, library != nil else {
            listener?.cancel()
            listener = nil
            status = ""
            return
        }
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(type: TVProtocol.serviceType)
            l.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                self?.receive(connection, Data())
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.status = "Waiting for Apple TV on port \(l.port?.rawValue ?? 0)"
                    case .failed(let error): self?.status = "Stopped: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
        }
    }

    // MARK: HTTP, one request per connection

    private struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func json<T: Encodable>(_ value: T) -> Response {
            Response(headers: ["Content-Type": "application/json"], body: (try? JSONEncoder().encode(value)) ?? Data())
        }
        static func error(_ status: Int, _ text: String) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain"], body: Data(text.utf8))
        }

        var encoded: Data {
            let reason = [200: "OK", 206: "Partial Content", 401: "Unauthorized", 404: "Not Found",
                          502: "Bad Gateway", 503: "Service Unavailable"][status] ?? "Error"
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            return Data(head.utf8) + body
        }
    }

    nonisolated private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                Task { @MainActor in
                    let response = await self?.respond(head) ?? .error(503, "Stopped")
                    await Self.send(response, on: connection)
                }
            } else if done || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self?.receive(connection, buffer)
            }
        }
    }

    nonisolated private static func send(_ response: Response, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: response.encoded, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }

    private func respond(_ head: String) async -> Response {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET",
              let url = URLComponents(string: "http://tv" + parts[1]) else { return .error(404, "Bad request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard query["k"] == code else { return .error(401, "Wrong pairing code") }
        guard let library, let lyrics, let player else { return .error(503, "Starting") }
        guard library.state == .ready else { return .error(503, "Tide on the Mac isn't signed in") }

        let path = url.path.split(separator: "/").map(String.init)
        let arg = path.count > 1 ? path[1] : ""
        switch path.first ?? "" {
        case "hello":
            return .json(TVProtocol.Hello(name: Host.current().localizedName ?? "Mac"))
        case "home":
            // The Mac fetches Home when it starts; a TV left on for hours asks again.
            if Date().timeIntervalSince(homeFetched) > 10 * 60 {
                homeFetched = Date()
                await library.refresh()
            }
            return .json(library.home)
        case "library":
            return .json(TVProtocol.LibraryList(playlists: library.playlists, albums: library.savedAlbums))
        case "page":
            guard let page = await library.page(arg) else { return .error(404, "No such page") }
            return .json(page)
        case "search":
            return .json(await library.search(query["q"] ?? ""))
        case "radio":
            guard let song = library.song(arg) else { return .json([Song]()) }
            return .json(await library.radio(after: song))
        case "lyrics":
            guard let song = library.song(arg) else { return .json(TVProtocol.Lyrics()) }
            await lyrics.load(song, duration: song.duration)
            let result: TVProtocol.Lyrics = switch lyrics.result(for: arg) {
            case .synced(let lines): TVProtocol.Lyrics(lines: lines)
            case .plain(let text): TVProtocol.Lyrics(plain: text)
            default: TVProtocol.Lyrics()
            }
            return .json(result)
        case "audio":
            return await audio(arg, range: headers["range"], resolver: player.resolver)
        case "video":
            return await audio(arg, range: headers["range"], resolver: player.resolver, video: true)
        case "settings":
            return .json(TVProtocol.Settings(smart: player.smartTransitions, smooth: player.smoothTransitions,
                                             crossfade: player.crossfade, gapless: player.gapless,
                                             matchLoudness: player.matchLoudness))
        case "gain":
            return .json((try? await player.resolver.resolve(arg, video: false, aac: true))?.gainDb ?? 0)
        case "plan":
            // The same plan the Mac would make for this pair (and the same cached analyses).
            let a = song(query["from"] ?? ""), b = song(query["to"] ?? "")
            guard let length = Double(query["length"] ?? ""), length > 30 else { return .error(404, "No length") }
            let resolver = player.resolver
            let plan = await TransitionStore.plan(from: a, length: length, to: b, fallbackFade: 5) { id in
                guard let streams = try? await resolver.resolve(id, video: false) else { return nil }
                return (streams.audio, streams.availableAt)
            }
            guard let plan else { return .error(404, "No plan") }
            return .json(plan)
        case "mood":
            return .json(await library.moodSongs(query["q"] ?? ""))
        default:
            return .error(404, "Not found")
        }
    }

    /// A song the library knows, or a bare one (the planner only needs its id there).
    private func song(_ id: String) -> Song {
        library?.song(id) ?? Song(id: id, title: "", artist: "", album: "", duration: 0)
    }

    /// Serves a byte range of the song from TVAudioFiles. Going through the Mac (rather
    /// than handing the TV the link) matters because YouTube ties each link to the
    /// address that asked for it.
    private func audio(_ videoId: String, range: String?, resolver: StreamResolver, video: Bool = false) async -> Response {
        let file: URL
        do {
            file = try await TVAudioFiles.shared.file(videoId, video: video, resolver: resolver)
        } catch {
            return .error(502, error.localizedDescription)
        }
        guard let handle = try? FileHandle(forReadingFrom: file), let total = try? handle.seekToEnd(), total > 0 else {
            return .error(502, "The song's file is missing")
        }
        defer { try? handle.close() }
        // "bytes=START-END" or "bytes=START-"; no header means the whole file.
        let bounds = (range ?? "").replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
        let start = min(UInt64(bounds.first.flatMap { Int($0) } ?? 0), total - 1)
        let end = min(bounds.count > 1 ? UInt64(bounds[1]).map { $0 } ?? total - 1 : total - 1, total - 1)
        try? handle.seek(toOffset: start)
        let data = (try? handle.read(upToCount: Int(end - start + 1))) ?? Data()
        return Response(status: 206, headers: [
            "Content-Type": video ? "video/mp4" : "audio/mp4",
            "Accept-Ranges": "bytes",
            "Content-Range": "bytes \(start)-\(start + UInt64(data.count) - 1)/\(total)",
        ], body: data)
    }
}

/// Songs for Apple TV, downloaded whole and rewritten from YouTube's fragmented MP4
/// into a plain one (ffmpeg, no re-encoding). AVPlayer misreads the fragmented kind:
/// it takes the songs to be twice as long and seeks tens of milliseconds off, which
/// would put every mix in the wrong place.
actor TVAudioFiles {
    static let shared = TVAudioFiles()

    private let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicApp/tv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var inFlight: [String: Task<URL, Error>] = [:]
    /// About 40 songs; the oldest go first.
    private static let keep = 40
    /// YouTube slows down single requests for more than about 10 MB.
    private static let piece = 8 << 20

    struct Failure: LocalizedError { let errorDescription: String? }

    /// `video`: the music video (H.264, up to 1080p) with the song's audio, as one MP4.
    func file(_ videoId: String, video: Bool = false, resolver: StreamResolver) async throws -> URL {
        let name = videoId + (video ? "-video.mp4" : ".m4a")
        let out = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: out.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: out.path)
            return out
        }
        if let running = inFlight[name] { return try await running.value }
        let directory = directory
        let task = Task<URL, Error> {
            let streams = try await resolver.resolve(videoId, video: video, aac: true)
            let wait = streams.availableAt.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            // Picture and sound come separately; both download at once.
            let sources = video ? [streams.video, streams.audio].compactMap { $0 } : [streams.audio]
            let parts = sources.indices.map { directory.appendingPathComponent("\(videoId)-\($0).part") }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (url, part) in zip(sources, parts) {
                    group.addTask { try await Self.download(url, to: part) }
                }
                try await group.waitForAll()
            }
            try Self.flatten(parts, to: out)
            parts.forEach { try? FileManager.default.removeItem(at: $0) }
            return out
        }
        inFlight[name] = task
        defer { inFlight[name] = nil }
        let url = try await task.value
        prune()
        return url
    }

    /// Fetches a whole stream in pieces into `file`.
    private static func download(_ url: URL, to file: URL) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var position = 0
        var total = Int.max
        while position < total {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(position)-\(position + piece - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206, !data.isEmpty,
                  let size = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int($0) })
            else { throw Failure(errorDescription: "YouTube refused the song") }
            total = size
            try handle.write(contentsOf: data)
            position += data.count
        }
    }

    /// Joins the downloaded parts into one plain MP4. Without ffmpeg a lone audio file
    /// is served as it is (playback works; timing is off) and videos can't be made.
    private static func flatten(_ parts: [URL], to out: URL) throws {
        guard let ffmpeg = AudioClip.ffmpeg else {
            guard parts.count == 1 else { throw Failure(errorDescription: "Videos need ffmpeg (brew install ffmpeg)") }
            return try FileManager.default.moveItem(at: parts[0], to: out)
        }
        let temp = out.deletingPathExtension().appendingPathExtension("tmp." + out.pathExtension)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-loglevel", "error", "-y"] + parts.flatMap { ["-i", $0.path] }
            + parts.indices.flatMap { ["-map", "\($0)"] }
            + ["-c", "copy", "-movflags", "+faststart", temp.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(errorDescription: "Couldn't prepare the song") }
        try FileManager.default.moveItem(at: temp, to: out)
    }

    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { ["m4a", "mp4"].contains($0.pathExtension) } ?? []
        guard files.count > Self.keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
