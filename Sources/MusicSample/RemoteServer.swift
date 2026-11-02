import AppKit
import Network
import TideLink

/// Lets the Tide iPhone app find this Mac on the local network, show and control
/// what's playing, and move playback back and forth (see Sources/TideLink).
@Observable final class RemoteServer {
    /// What the phone is playing by itself, for Home's "Continue from iPhone".
    var phone: LinkState?
    var phoneName = "iPhone"

    @ObservationIgnored private let player: Player
    @ObservationIgnored private var listeners: [NWListener] = []
    @ObservationIgnored private var clients: [LinkConnection] = []
    @ObservationIgnored private weak var phoneClient: LinkConnection?
    @ObservationIgnored private var sentState: LinkState?
    @ObservationIgnored private var sentAt = Date()
    @ObservationIgnored private var sentQueue: LinkQueue?
    @ObservationIgnored private var timer: Timer?

    init(player: Player) {
        self.player = player
        let name = Host.current().localizedName ?? "Mac"
        if let control = Self.listener(LinkConnection.parameters, Link.controlPort) {
            control.service = .init(name: name, type: Link.controlService)
            control.newConnectionHandler = { [weak self] in self?.accept($0) }
            listeners.append(control)
        }
        let tcp = NWParameters.tcp
        tcp.includePeerToPeer = true
        if let audio = Self.listener(tcp, Link.audioPort) {
            audio.service = .init(name: name, type: Link.audioService)
            audio.newConnectionHandler = { [weak self] in self?.serveAudio($0) }
            listeners.append(audio)
        }
        listeners.forEach { $0.start(queue: .main) }
        // Checked once a second, sent only when something changed.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.broadcast() }
    }

    /// On the fixed port when it's free, otherwise any (Bonjour still finds it).
    private static func listener(_ params: NWParameters, _ port: UInt16) -> NWListener? {
        (try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)) ?? (try? NWListener(using: params))
    }

    /// This Mac's Tailscale addresses (100.64.0.0/10), for the phone to use away from home.
    private static var tailscaleHosts: [String] {
        var hosts: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var next = list
        while let a = next?.pointee {
            next = a.ifa_next
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard ip >> 22 == (100 << 2 | 1) else { continue }
            hosts.append("\(ip >> 24).\(ip >> 16 & 255).\(ip >> 8 & 255).\(ip & 255)")
        }
        return hosts
    }

    /// "Resume Here": the phone pauses and sends back its queue and spot.
    func pullFromPhone() {
        phoneClient?.send(.handoffRequest)
    }

    private func accept(_ connection: NWConnection) {
        let client = LinkConnection(connection)
        client.onReady = { [weak self, unowned client] in
            guard let self else { return }
            client.send(.hello(name: Host.current().localizedName ?? "Mac", hosts: Self.tailscaleHosts))
            client.send(.state(self.state))
            client.send(.queue(self.queue))
        }
        client.onMessage = { [weak self, unowned client] in self?.handle($0, from: client) }
        client.onClose = { [weak self, unowned client] in
            guard let self else { return }
            self.clients.removeAll { $0 === client }
            if self.phoneClient == nil || self.phoneClient === client { self.phone = nil }
        }
        clients.append(client)
        client.start()
    }

    private func handle(_ message: LinkMessage, from client: LinkConnection) {
        switch message {
        case .hello(let name, _):
            phoneName = name
        case .command(let command):
            switch command {
            case .toggle: player.toggle()
            case .next: player.next()
            case .previous: player.previous()
            case .seek(let t): player.seek(t)
            case .volume(let v): player.volume = min(1, max(0, v))
            case .jump(let i): player.jump(to: i)
            case .play(let songs, let i): player.take(songs.map(Song.init), at: i, from: 0)
            }
            broadcast()
        case .state(let state):
            phoneClient = client
            phone = state.song == nil ? nil : state
        case .handoffRequest:
            // The phone takes over: it gets the queue around the current song.
            guard player.current != nil else { return }
            let start = max(0, player.index - 50)
            let end = min(player.queue.count, player.index + 500)
            if player.isPlaying { player.toggle() }
            client.send(.handoff(LinkHandoff(songs: player.queue[start..<end].map(\.link),
                                             index: player.index - start, position: player.position)))
        case .handoff(let handoff):
            phone = nil
            player.take(handoff.songs.map(Song.init), at: handoff.index, from: handoff.position)
        case .queue:
            break
        }
    }

    private var state: LinkState {
        LinkState(song: player.current?.link, playing: player.isPlaying, position: player.position,
                  duration: player.length, volume: player.volume)
    }

    private var queue: LinkQueue {
        guard player.current != nil else { return .empty }
        let start = max(0, player.index - 20)
        let end = min(player.queue.count, player.index + 100)
        return LinkQueue(songs: player.queue[start..<end].map(\.link), first: start, index: player.index)
    }

    private func broadcast() {
        guard !clients.isEmpty else { return }
        let now = state
        if let last = sentState {
            let expected = last.position + (last.playing ? Date().timeIntervalSince(sentAt) : 0)
            let same = last.song == now.song && last.playing == now.playing
                && abs(last.volume - now.volume) < 0.005 && abs(last.duration - now.duration) < 0.5
                && abs(expected - now.position) < 1.5
            if !same { send(.state(now)) }
        } else {
            send(.state(now))
        }
        let q = queue
        if q != sentQueue {
            sentQueue = q
            clients.forEach { $0.send(.queue(q)) }
        }
    }

    private func send(_ message: LinkMessage) {
        if case .state(let s) = message {
            sentState = s
            sentAt = Date()
        }
        clients.forEach { $0.send(message) }
    }

    /// The phone asks "<videoId> <std|low> <now|ahead>\n" and gets an 8-byte length,
    /// then the m4a file; a zero length means it couldn't be had.
    private func serveAudio(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, _, _ in
            let parts = String(decoding: data ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
            guard let self, parts.count == 3, parts[0].count == 11 else { return connection.cancel() }
            Task { @MainActor in
                let body = (try? await self.player.resolver.phoneAudio(parts[0], low: parts[1] == "low",
                                                                       ahead: parts[2] == "ahead")) ?? Data()
                var length = UInt64(body.count).bigEndian
                connection.send(content: Data(bytes: &length, count: 8) + body,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

extension Song {
    var link: LinkSong {
        LinkSong(id: id, title: title, artist: artist, album: album, duration: duration, artwork: artwork)
    }

    init(_ s: LinkSong) {
        self.init(id: s.id, title: s.title, artist: s.artist, album: s.album, duration: s.duration, artwork: s.artwork)
    }
}
