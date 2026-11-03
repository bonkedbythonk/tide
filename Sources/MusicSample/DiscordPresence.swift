import Foundation

/// Shows the current song as your Discord status ("Listening to Tide"), through the
/// local socket the Discord app opens for this. Does nothing while Discord is closed
/// and connects again on the next change once it's open.
final class DiscordPresence {
    /// Tide's application on Discord's developer portal: it supplies the name shown.
    private static let clientID = "1567179753813975041"

    private let queue = DispatchQueue(label: "discord presence")
    private var socket: Int32 = -1
    private var pending: DispatchWorkItem?

    /// Discord allows about five updates every 20 s, so quick changes are merged.
    func update(song: Song?, position: TimeInterval, duration: TimeInterval, playing: Bool) {
        pending?.cancel()
        let activity = song.flatMap { playing ? Self.activity($0, position: position, duration: duration) : nil }
        let work = DispatchWorkItem { [weak self] in self?.send(activity) }
        pending = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func clear() { update(song: nil, position: 0, duration: 0, playing: false) }

    private static func activity(_ song: Song, position: TimeInterval, duration: TimeInterval) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        var activity: [String: Any] = [
            "type": 2,  // Listening
            "details": String(song.title.prefix(128)),
            "state": String(song.artist.prefix(128)),
            "buttons": [["label": "Listen on YouTube Music", "url": "https://music.youtube.com/watch?v=\(song.id)"]],
        ]
        if duration > 0 {
            let start = now - position
            activity["timestamps"] = ["start": Int(start * 1000), "end": Int((start + duration) * 1000)]
        }
        var assets: [String: Any] = [:]
        if let art = song.artwork?.absoluteString, art.hasPrefix("https://") { assets["large_image"] = art }
        if !song.album.isEmpty { assets["large_text"] = String(song.album.prefix(128)) }
        if !assets.isEmpty { activity["assets"] = assets }
        return activity
    }

    private func send(_ activity: [String: Any]?) {
        guard connect() else { return }
        var args: [String: Any] = ["pid": Int(getpid())]
        if let activity { args["activity"] = activity }
        let payload: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]
        // Each update gets a reply; reading it keeps the socket from filling up.
        if !(write(op: 1, payload) && read()) {
            disconnect()
            // Discord restarted since the last update: connect again once.
            if connect(), write(op: 1, payload) { _ = read() }
        }
    }

    private func connect() -> Bool {
        if socket >= 0 { return true }
        let dirs = [ProcessInfo.processInfo.environment["TMPDIR"], NSTemporaryDirectory(), "/tmp/"].compactMap { $0 }
        for dir in dirs {
            for n in 0..<10 {
                let path = (dir as NSString).appendingPathComponent("discord-ipc-\(n)")
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                    let bytes = Array(path.utf8.prefix(raw.count - 1))
                    raw.copyBytes(from: bytes)
                }
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                    }
                }
                guard ok else { close(fd); continue }
                socket = fd
                guard write(op: 0, ["v": 1, "client_id": Self.clientID]), read() else {
                    disconnect()
                    return false
                }
                return true
            }
        }
        return false
    }

    private func disconnect() {
        if socket >= 0 { close(socket) }
        socket = -1
    }

    /// One frame: opcode and length (little-endian UInt32s), then the JSON.
    private func write(op: UInt32, _ payload: [String: Any]) -> Bool {
        guard socket >= 0, let json = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        return frame.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, frame.count) } == frame.count
    }

    /// Reads and drops one reply frame.
    private func read() -> Bool {
        var header = [UInt8](repeating: 0, count: 8)
        guard Darwin.read(socket, &header, 8) == 8 else { return false }
        let length = Int(header[4]) | Int(header[5]) << 8 | Int(header[6]) << 16 | Int(header[7]) << 24
        var body = [UInt8](repeating: 0, count: length)
        var got = 0
        while got < length {
            let n = body.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress! + got, length - got) }
            guard n > 0 else { return false }
            got += n
        }
        return true
    }
}
