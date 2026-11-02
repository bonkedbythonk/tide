import Foundation

/// Keeps one yt-dlp process running (as a library, in Homebrew yt-dlp's own Python)
/// instead of starting yt-dlp for every song: about 1.7 s per song instead of ~2.9 s.
/// Returns nil whenever it can't help, and the caller falls back to plain yt-dlp.
actor YTDLPWorker {
    static let shared = YTDLPWorker()

    struct Result {
        let urls: [URL]
        let availableAt: Double
    }

    private static let python = "/opt/homebrew/opt/yt-dlp/libexec/bin/python3"

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]

    func resolve(url: String, format: String, client: String?) async -> Result? {
        guard ensureRunning(), let input else { return nil }
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["id": id, "url": url, "format": format, "client": client ?? NSNull()]
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        line.append(10)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.finish(id, with: nil)
        }
        let reply = await withCheckedContinuation { continuation in
            pending[id] = continuation
            input.write(line)
        }
        guard let reply, reply["ok"] as? Bool == true,
              let strings = reply["urls"] as? [String], !strings.isEmpty else { return nil }
        return Result(urls: strings.compactMap(URL.init(string:)),
                      availableAt: reply["available_at"] as? Double ?? 0)
    }

    private func finish(_ id: Int, with reply: [String: Any]?) {
        pending.removeValue(forKey: id)?.resume(returning: reply)
    }

    private func ensureRunning() -> Bool {
        if process?.isRunning == true { return true }
        guard FileManager.default.isExecutableFile(atPath: Self.python) else { return false }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("ytdlp_worker.py")
        guard (try? Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil else { return false }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        p.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"  // deno, for YouTube's JS challenge
        p.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice

        // Replies are matched by id, so complete lines can be handed over in any order.
        let buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in buffer.append(handle.availableData) {
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = json["id"] as? Int, id > 0 else { continue }
                Task { await self?.finish(id, with: json) }
            }
        }
        p.terminationHandler = { [weak self] _ in Task { await self?.stopped() } }
        guard (try? p.run()) != nil else { return false }
        process = p
        input = stdin.fileHandleForWriting
        return true
    }

    private func stopped() {
        process = nil
        input = nil
        for continuation in pending.values { continuation.resume(returning: nil) }
        pending = [:]
    }

    private final class LineBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) -> [Data] {
            lock.withLock {
                data.append(chunk)
                var lines: [Data] = []
                while let newline = data.firstIndex(of: 10) {
                    lines.append(data[data.startIndex..<newline])
                    data.removeSubrange(data.startIndex...newline)
                }
                return lines
            }
        }
    }

    private static let script = #"""
"""Long-running yt-dlp worker for the music app.

Reads one JSON request per line on stdin, answers one JSON line on stdout:
  -> {"id": 1, "url": "https://...", "format": "ba/b", "client": "web_embedded"}
  <- {"id": 1, "ok": true, "urls": ["https://..."], "available_at": 1793628569}
  <- {"id": 1, "ok": false, "error": "..."}

Staying alive saves Python and yt-dlp start-up on every song, and each thread
keeps its own YoutubeDL, so YouTube's player script stays cached between songs.
"""
import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

import yt_dlp

out_lock = threading.Lock()
local = threading.local()


def downloader(client, fmt):
    # One YoutubeDL per (client, format): yt-dlp builds its format selector once,
    # in __init__, so changing params["format"] on a reused instance is ignored.
    cache = getattr(local, "ydls", None)
    if cache is None:
        cache = local.ydls = {}
    key = (client, fmt)
    if key not in cache:
        opts = {"quiet": True, "no_warnings": True, "noplaylist": True, "skip_download": True, "format": fmt}
        if client:
            opts["extractor_args"] = {"youtube": {"player_client": [client]}}
        cache[key] = yt_dlp.YoutubeDL(opts)
    return cache[key]


def answer(message):
    with out_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def handle(request):
    try:
        ydl = downloader(request.get("client"), request["format"])
        info = ydl.extract_info(request["url"], download=False)
        formats = info.get("requested_formats") or [info]
        urls = [f["url"] for f in formats if f.get("url")]
        available = max([f.get("available_at") or 0 for f in formats] + [info.get("available_at") or 0])
        answer({"id": request["id"], "ok": bool(urls), "urls": urls, "available_at": available,
                "error": None if urls else "no stream URL"})
    except Exception as error:  # report every failure back; the app falls back to plain yt-dlp
        answer({"id": request["id"], "ok": False, "error": str(error).splitlines()[-1] if str(error) else repr(error)})


def main():
    pool = ThreadPoolExecutor(max_workers=3)
    answer({"id": 0, "ok": True, "ready": True})
    for line in sys.stdin:
        line = line.strip()
        if line:
            pool.submit(handle, json.loads(line))


if __name__ == "__main__":
    main()
"""#
}
