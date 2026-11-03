import AppKit

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
            // What the line under your name shows: 1 = the artist (state), not "Tide".
            "status_display_type": 1,
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

/// Discord's logo; drawn as a template so it takes the player bar's colours.
enum DiscordLogo {
    static let image: NSImage = {
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -28.5 256 256"><path fill="#5865F2" d="M216.856339,16.5966031 C200.285002,8.84328665 182.566144,3.2084988 164.041564,0 C161.766523,4.11318106 159.108624,9.64549908 157.276099,14.0464379 C137.583995,11.0849896 118.072967,11.0849896 98.7430163,14.0464379 C96.9108417,9.64549908 94.1925838,4.11318106 91.8971895,0 C73.3526068,3.2084988 55.6133949,8.86399117 39.0420583,16.6376612 C5.61752293,67.146514 -3.4433191,116.400813 1.08711069,164.955721 C23.2560196,181.510915 44.7403634,191.567697 65.8621325,198.148576 C71.0772151,190.971126 75.7283628,183.341335 79.7352139,175.300261 C72.104019,172.400575 64.7949724,168.822202 57.8887866,164.667963 C59.7209612,163.310589 61.5131304,161.891452 63.2445898,160.431257 C105.36741,180.133187 151.134928,180.133187 192.754523,160.431257 C194.506336,161.891452 196.298154,163.310589 198.110326,164.667963 C191.183787,168.842556 183.854737,172.420929 176.223542,175.320965 C180.230393,183.341335 184.861538,190.991831 190.096624,198.16893 C211.238746,191.588051 232.743023,181.531619 254.911949,164.955721 C260.227747,108.668201 245.831087,59.8662432 216.856339,16.5966031 Z M85.4738752,135.09489 C72.8290281,135.09489 62.4592217,123.290155 62.4592217,108.914901 C62.4592217,94.5396472 72.607595,82.7145587 85.4738752,82.7145587 C98.3405064,82.7145587 108.709962,94.5189427 108.488529,108.914901 C108.508531,123.290155 98.3405064,135.09489 85.4738752,135.09489 Z M170.525237,135.09489 C157.88039,135.09489 147.510584,123.290155 147.510584,108.914901 C147.510584,94.5396472 157.658606,82.7145587 170.525237,82.7145587 C183.391518,82.7145587 193.761324,94.5189427 193.539891,108.914901 C193.539891,123.290155 183.391518,135.09489 170.525237,135.09489 Z"/></svg>"##
        return NSImage(data: Data(svg.utf8)) ?? NSImage()
    }()
}
