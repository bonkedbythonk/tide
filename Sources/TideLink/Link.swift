import Foundation
import Network

/// What the Mac app and the iPhone app say to each other over the local network.
/// Compiled into both: a SwiftPM target for the Mac, plain sources for the iOS app.
///
/// Two Bonjour services: `control` is a WebSocket carrying small JSON messages
/// (state, Up Next, commands, handoff); `audio` hands the phone an m4a file
/// when it takes over playback, so the control channel never carries audio.
public enum Link {
    public static let controlService = "_tide._tcp"
    public static let audioService = "_tide-audio._tcp"
}

public struct LinkSong: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public var album: String
    public let duration: TimeInterval
    public var artwork: URL?

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, artwork: URL?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
    }
}

/// The receiver works out the live position from `position` and when the
/// message arrived, so state is only sent when something actually changes.
public struct LinkState: Codable, Equatable, Sendable {
    public var song: LinkSong?
    public var playing: Bool
    public var position: TimeInterval
    public var duration: TimeInterval
    public var volume: Double

    public static let empty = LinkState(song: nil, playing: false, position: 0, duration: 0, volume: 1)

    public init(song: LinkSong?, playing: Bool, position: TimeInterval, duration: TimeInterval, volume: Double) {
        self.song = song
        self.playing = playing
        self.position = position
        self.duration = duration
        self.volume = volume
    }
}

/// A window of the queue around the current song. Indices are into the whole
/// queue, so `jump` works on radio queues longer than the window.
public struct LinkQueue: Codable, Equatable, Sendable {
    public var songs: [LinkSong]
    /// Queue index of `songs[0]`.
    public var first: Int
    /// Queue index of the current song.
    public var index: Int

    public static let empty = LinkQueue(songs: [], first: 0, index: 0)

    public init(songs: [LinkSong], first: Int, index: Int) {
        self.songs = songs
        self.first = first
        self.index = index
    }
}

/// Playback moving from one device to the other.
public struct LinkHandoff: Codable, Sendable {
    public var songs: [LinkSong]
    public var index: Int
    public var position: TimeInterval

    public init(songs: [LinkSong], index: Int, position: TimeInterval) {
        self.songs = songs
        self.index = index
        self.position = position
    }
}

public enum LinkCommand: Codable, Sendable {
    case toggle, next, previous
    case seek(TimeInterval)
    case volume(Double)
    case jump(Int)
}

public enum LinkMessage: Codable, Sendable {
    case hello(name: String)
    /// The sender's playback. The phone only sends it while it plays by itself.
    case state(LinkState)
    case queue(LinkQueue)
    case command(LinkCommand)
    /// "Give me playback": the other side pauses and answers with `handoff`.
    case handoffRequest
    case handoff(LinkHandoff)
}

/// One control connection, either end. Callbacks arrive on the main queue.
public final class LinkConnection {
    public var onReady: (() -> Void)?
    public var onMessage: ((LinkMessage) -> Void)?
    public var onClose: (() -> Void)?
    private let connection: NWConnection
    private var closed = false

    /// TCP with WebSocket framing, for both the listener and the connection.
    public static var parameters: NWParameters {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = true
        return params
    }

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed, .cancelled: self?.close()
            // Unreachable (asleep, other network): give up and let discovery retry.
            case .waiting: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    public func send(_ message: LinkMessage) {
        guard !closed, let data = try? JSONEncoder().encode(message) else { return }
        let context = NWConnection.ContentContext(identifier: "message",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    public func cancel() { close() }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let message = try? JSONDecoder().decode(LinkMessage.self, from: data) {
                self.onMessage?(message)
            }
            if error == nil, !self.closed { self.receive() } else { self.close() }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }
}
