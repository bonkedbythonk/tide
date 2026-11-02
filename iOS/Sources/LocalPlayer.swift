import AVFoundation
import MediaPlayer
import Network

/// Playback on the phone itself, after "Continue on iPhone". The audio comes from
/// the Mac as an m4a file over the local network: the phone never asks YouTube
/// for a stream, so nothing plays over cellular and no video is ever fetched.
@Observable final class LocalPlayer {
    var queue: [LinkSong] = []
    var index = 0
    var playing = false
    var loading = false
    var error: String?
    var volume = 1.0 { didSet { player.volume = Float(volume) } }

    /// The Mac's Bonjour name; audio can't be had without it.
    @ObservationIgnored var mac: String?
    /// Something changed that the Mac should hear about (its "Continue from iPhone").
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var token = 0

    var current: LinkSong? { queue.indices.contains(index) ? queue[index] : nil }

    var position: TimeInterval {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    var state: LinkState {
        LinkState(song: current, playing: playing, position: position,
                  duration: current?.duration ?? 0, volume: volume)
    }

    init() {
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.next() }
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.playCommand.addTarget { [weak self] _ in if self?.playing == false { self?.toggle() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }

    func take(_ handoff: LinkHandoff) {
        queue = handoff.songs
        index = handoff.index
        load(at: handoff.position)
    }

    var handoff: LinkHandoff { LinkHandoff(songs: queue, index: index, position: position) }

    func apply(_ command: LinkCommand) {
        switch command {
        case .toggle: toggle()
        case .next: next()
        case .previous: previous()
        case .seek(let t): seek(t)
        case .volume(let v): volume = v
        case .jump(let i): if queue.indices.contains(i) { index = i; load() }
        }
    }

    func toggle() {
        guard current != nil else { return }
        if player.currentItem == nil || error != nil { return load(at: position) }
        playing ? pause() : play()
    }

    func pause() {
        player.pause()
        playing = false
        changed()
    }

    private func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        playing = true
        changed()
    }

    func next() {
        guard index + 1 < queue.count else { return pause() }
        index += 1
        load()
    }

    func previous() {
        if position > 3 || index == 0 { return seek(0) }
        index -= 1
        load()
    }

    func seek(_ t: TimeInterval) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        changed()
    }

    /// Gets the song's file (cached, or from the Mac), plays it, then fetches the
    /// next one ahead when that costs no mobile data.
    private func load(at start: TimeInterval = 0) {
        guard let song = current else { return }
        token += 1
        let mine = token
        loading = true
        error = nil
        player.pause()
        changed()
        Task { @MainActor in
            do {
                let file = try await AudioFiles.file(for: song.id, from: mac, ahead: false)
                guard mine == token else { return }
                player.replaceCurrentItem(with: AVPlayerItem(url: file))
                if start > 0 { await player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
                loading = false
                play()
                if queue.indices.contains(index + 1), AudioFiles.canDownloadAhead {
                    _ = try? await AudioFiles.file(for: queue[index + 1].id, from: mac, ahead: true)
                }
            } catch {
                guard mine == token else { return }
                loading = false
                playing = false
                self.error = mac == nil ? "Not downloaded yet. Open Tide on your Mac on the same Wi-Fi."
                                        : "Your Mac couldn't get this song."
                changed()
            }
        }
    }

    private func changed() {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: current?.title ?? "",
            MPMediaItemPropertyArtist: current?.artist ?? "",
            MPMediaItemPropertyPlaybackDuration: current?.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = current == nil ? nil : info
        onChange?()
    }
}

/// Songs downloaded from the Mac, kept in Caches so a song plays again without
/// fetching it twice, and so playback carries on after leaving the Mac's Wi-Fi.
enum AudioFiles {
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let keep = 60

    /// Data saver: about 48 kbps instead of 128.
    static var dataSaver: Bool { UserDefaults.standard.bool(forKey: "dataSaver") }

    private static let path = NWPathMonitor()
    private static let startMonitor: Void = path.start(queue: .main)

    /// Only on Wi-Fi or wired, and not in Low Data Mode.
    static var canDownloadAhead: Bool {
        _ = startMonitor
        return !path.currentPath.isExpensive && !path.currentPath.isConstrained
    }

    static func file(for id: String, from mac: String?, ahead: Bool) async throws -> URL {
        for quality in ["std", "low"] {
            let url = directory.appendingPathComponent("\(id)-\(quality).m4a")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let mac else { throw URLError(.notConnectedToInternet) }
        let quality = dataSaver ? "low" : "std"
        let data = try await download("\(id) \(quality) \(ahead ? "ahead" : "now")\n", from: mac)
        let url = directory.appendingPathComponent("\(id)-\(quality).m4a")
        try data.write(to: url, options: .atomic)
        trim()
        return url
    }

    static var size: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Keeps the most recent downloads only.
    private static func trim() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The Mac's audio service: one request line, then an 8-byte length and the file.
    private static func download(_ request: String, from mac: String) async throws -> Data {
        let connection = NWConnection(to: .service(name: mac, type: Link.audioService, domain: "local.", interface: nil),
                                      using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
            // Every callback runs on the main queue.
            nonisolated(unsafe) var finished = false
            @Sendable func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed(let e), .waiting(let e): finish(.failure(e))
                default: break
                }
            }
            connection.start(queue: .main)
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { head, _, _, error in
                guard let head, head.count == 8 else { return finish(.failure(error ?? URLError(.badServerResponse))) }
                let length = head.reduce(0) { $0 << 8 | Int($1) }
                guard length > 0 else { return finish(.failure(URLError(.resourceUnavailable))) }
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                    if let body, body.count == length { finish(.success(body)) } else {
                        finish(.failure(error ?? URLError(.networkConnectionLost)))
                    }
                }
            }
        }
    }
}
