import Foundation
import Network
import UIKit

/// Finds Tide on the Mac with Bonjour, mirrors what it plays, and decides where
/// commands go: to the Mac, or to the phone's own player after a handoff.
@Observable final class Remote {
    enum Target { case mac, phone }

    var macName: String?
    var connected = false
    var target = Target.mac
    /// A handoff to the phone was asked for and hasn't arrived yet.
    var handingOff = false
    let local = LocalPlayer()

    private(set) var macState = LinkState.empty
    private(set) var macQueue = LinkQueue.empty
    /// When `macState` arrived; its position is worked out from here.
    @ObservationIgnored private var macStateAt = Date()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var link: LinkConnection?

    init() {
        local.onChange = { [weak self] in self?.reportLocal() }
        // The last state, so the app opens showing something before it finds the Mac.
        if let data = try? Data(contentsOf: Self.snapshot),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            macName = saved.mac
            macState = saved.state
            macState.playing = false
            macQueue = saved.queue
        }
    }

    var state: LinkState { target == .phone ? local.state : macState }

    var queue: LinkQueue {
        target == .phone ? LinkQueue(songs: local.queue, first: 0, index: local.index) : macQueue
    }

    func position(at date: Date) -> TimeInterval {
        if target == .phone { return local.position }
        guard macState.playing else { return macState.position }
        return min(macState.duration, macState.position + date.timeIntervalSince(macStateAt))
    }

    func send(_ command: LinkCommand) {
        guard target == .mac else { return local.apply(command) }
        link?.send(.command(command))
        // Show the change straight away instead of waiting for the Mac's answer.
        switch command {
        case .toggle:
            macState.position = position(at: .now)
            macStateAt = .now
            macState.playing.toggle()
        case .seek(let t):
            macState.position = t
            macStateAt = .now
        case .volume(let v):
            macState.volume = v
        default: break
        }
    }

    /// The Mac pauses and sends its queue and spot; playback carries on here.
    func continueOnPhone() {
        guard connected, macState.song != nil else { return }
        handingOff = true
        link?.send(.handoffRequest)
    }

    func continueOnMac() {
        guard connected, local.current != nil else { return }
        link?.send(.handoff(local.handoff))
        // Switched first, so the pause isn't reported back as something still to resume.
        target = .mac
        local.pause()
    }

    // MARK: Connection

    /// Called when the app comes to the front; a no-op while connected.
    func start() {
        guard link == nil else { return }
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: Link.controlService, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.connect(results) }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connect(_ results: Set<NWBrowser.Result>) {
        guard link == nil, let result = results.first(where: { Self.name(of: $0) == macName }) ?? results.first,
              let name = Self.name(of: result) else { return }
        let link = LinkConnection(NWConnection(to: result.endpoint, using: LinkConnection.parameters))
        link.onReady = { [weak self, unowned link] in
            guard let self else { return }
            self.connected = true
            self.macName = name
            self.local.mac = name
            link.send(.hello(name: UIDevice.current.name))
            self.reportLocal()
        }
        link.onMessage = { [weak self] in self?.handle($0) }
        link.onClose = { [weak self, unowned link] in
            guard let self, self.link === link else { return }
            self.link = nil
            self.connected = false
            self.handingOff = false
            self.local.mac = nil
            // Try again shortly: the Mac app may have restarted, or Wi-Fi blinked.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let results = self.browser?.browseResults { self.connect(results) }
            }
        }
        self.link = link
        link.start()
    }

    private static func name(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { name } else { nil }
    }

    private func handle(_ message: LinkMessage) {
        switch message {
        case .state(let state):
            let newSong = state.song?.id != macState.song?.id
            macState = state
            macStateAt = .now
            if newSong { save() }
        case .queue(let queue):
            macQueue = queue
            save()
        case .handoff(let handoff):
            handingOff = false
            target = .phone
            local.volume = macState.volume
            local.take(handoff)
        case .handoffRequest:
            // "Resume Here" on the Mac.
            if target == .phone { continueOnMac() }
        case .hello, .command:
            break
        }
    }

    /// Tells the Mac what plays here, for its "Continue from iPhone" banner.
    private func reportLocal() {
        guard target == .phone else { return }
        link?.send(.state(local.state))
    }

    // MARK: Snapshot

    private struct Snapshot: Codable {
        let mac: String?
        let state: LinkState
        let queue: LinkQueue
    }

    private static let snapshot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("last-state.json")

    private func save() {
        let data = try? JSONEncoder().encode(Snapshot(mac: macName, state: macState, queue: macQueue))
        try? data?.write(to: Self.snapshot, options: .atomic)
    }
}
