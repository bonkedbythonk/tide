import Foundation

/// Turns a videoId into playable stream URLs with yt-dlp. Results are kept for
/// a few hours (YouTube's links stay valid for about six), and upcoming tracks
/// are resolved ahead of time so pressing play or skipping doesn't wait on yt-dlp.
actor StreamResolver {
    struct Streams {
        let audio: URL
        let video: URL?
        let resolvedAt: Date
        /// YouTube's links answer 403 until a few seconds after they're issued
        /// (yt-dlp: "Sleeping 6.00 seconds as required by the site").
        let availableAt: Date
        /// How far YouTube Music turns this track down (dB, 0 or negative).
        var gainDb: Double = 0
    }

    enum Failure: LocalizedError {
        case missingTool
        case ytdlp(String)

        var errorDescription: String? {
            switch self {
            case .missingTool: "yt-dlp not found. Install it with: brew install yt-dlp"
            case .ytdlp(let message): message
            }
        }
    }

    private var cache: [String: Streams] = [:]
    private var inFlight: [String: Task<Streams, Error>] = [:]

    private static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    private static let executable: URL? = searchPath
        .map { URL(fileURLWithPath: $0).appendingPathComponent("yt-dlp") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    func resolve(_ videoId: String, video: Bool, maxHeight: Int = 1080) async throws -> Streams {
        let key = videoId + (video ? "#v\(maxHeight)" : "#a")
        if let hit = cache[key], hit.resolvedAt.timeIntervalSinceNow > -4 * 3600 { return hit }
        if let running = inFlight[key] { return try await running.value }
        let task = Task {
            async let gain = Self.loudnessGain(videoId)
            var streams: Streams
            // Audio: the embedded-player client's links work immediately, the default
            // client's only after a ~5 s wait. Videos stay on the default client, which
            // has HD; the embedded one stops around 720p.
            if !video, let fast = try? await Self.run(videoId, video: false, maxHeight: maxHeight, client: "web_embedded") {
                streams = fast
            } else {
                streams = try await Self.run(videoId, video: video, maxHeight: maxHeight, client: nil)
            }
            streams.gainDb = await gain
            return streams
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let streams = try await task.value
        cache[key] = streams
        return streams
    }

    private var prefetchQueue: [(id: String, video: Bool, maxHeight: Int)] = []
    private var prefetchesRunning = 0

    /// Resolves songs in the background, two at a time, so a long queue doesn't
    /// start a crowd of yt-dlp processes at once. Newer requests go first.
    func prefetch(_ videoIds: [String], video: Bool, maxHeight: Int) {
        let fresh = videoIds.filter { id in
            let key = id + (video ? "#v\(maxHeight)" : "#a")
            let cached = cache[key].map { $0.resolvedAt.timeIntervalSinceNow > -4 * 3600 } ?? false
            return !cached && inFlight[key] == nil && !prefetchQueue.contains { $0.id == id && $0.video == video }
        }
        prefetchQueue.insert(contentsOf: fresh.map { ($0, video, maxHeight) }, at: 0)
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while prefetchesRunning < 2, !prefetchQueue.isEmpty {
            let next = prefetchQueue.removeFirst()
            prefetchesRunning += 1
            Task {
                _ = try? await resolve(next.id, video: next.video, maxHeight: next.maxHeight)
                prefetchFinished()
            }
        }
    }

    private func prefetchFinished() {
        prefetchesRunning -= 1
        pumpPrefetch()
    }

    /// YouTube Music plays loud masters quieter: it measures each track (LKFS) and
    /// turns it down to a target of -14, never up. The iOS client's player response
    /// carries both numbers. Any failure means 0, i.e. play as mastered.
    private static func loudnessGain(_ videoId: String) async -> Double {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": ["clientName": "IOS", "clientVersion": "20.10.4", "hl": "en"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audio = (json["playerConfig"] as? [String: Any])?["audioConfig"] as? [String: Any],
              let track = (audio["trackAbsoluteLoudnessLkfs"] ?? audio["perceptualLoudnessDb"]) as? Double
        else { return 0 }
        let target = audio["loudnessTargetLkfs"] as? Double ?? -14
        return min(0, target - track)
    }

    private static func run(_ videoId: String, video: Bool, maxHeight: Int, client: String?) async throws -> Streams {
        let format = video ? "bv*[height<=\(maxHeight)]+ba/b[height<=\(maxHeight)]/b" : "ba/b"
        let page = video ? "https://www.youtube.com/watch?v=" : "https://music.youtube.com/watch?v="
        if let warm = await YTDLPWorker.shared.resolve(url: page + videoId, format: format, client: client),
           let first = warm.urls.first {
            let availableAt = Date(timeIntervalSince1970: warm.availableAt)
            // Separate video and audio streams come back as two URLs: video, then audio.
            return warm.urls.count >= 2
                ? Streams(audio: warm.urls[1], video: first, resolvedAt: .now, availableAt: availableAt)
                : Streams(audio: first, video: video ? first : nil, resolvedAt: .now, availableAt: availableAt)
        }
        guard let executable else { throw Failure.missingTool }
        let process = Process()
        process.executableURL = executable
        process.arguments = (client.map { ["--extractor-args", "youtube:player_client=\($0)"] } ?? []) + [
            "--no-warnings", "--no-playlist", "-f", format,
            "--print", "%(requested_formats.0.available_at,available_at|0)s",
            "--print", "%(requested_formats.0.url,url)s",
            "--print", "%(requested_formats.1.url|)s",
            page + videoId,
        ]
        // Apps launched from Finder get a bare PATH; yt-dlp needs deno from Homebrew
        // for YouTube's JavaScript challenge.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard p.terminationStatus == 0, lines.count >= 2, let first = URL(string: lines[1]) else {
                    let line = stderr.split(separator: "\n").last.map(String.init) ?? "yt-dlp exited with \(p.terminationStatus)"
                    continuation.resume(throwing: Failure.ytdlp(line))
                    return
                }
                let availableAt = Date(timeIntervalSince1970: Double(lines[0]) ?? 0)
                // Separate video and audio streams come back as two URLs: video, then audio.
                let second = lines.count > 2 ? URL(string: lines[2]) : nil
                let streams = second.map { Streams(audio: $0, video: first, resolvedAt: .now, availableAt: availableAt) }
                    ?? Streams(audio: first, video: video ? first : nil, resolvedAt: .now, availableAt: availableAt)
                continuation.resume(returning: streams)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
