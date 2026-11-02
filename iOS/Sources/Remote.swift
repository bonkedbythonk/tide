import Foundation
import Network
import UIKit

/// Finds Tide on the Mac (Bonjour at home, its Tailscale address away), mirrors
/// what it plays, and decides where playback happens: on the Mac, controlled
/// from here, or on the phone.
@Observable final class Remote {
    enum Target { case mac, phone }

    var macName: String?
    var connected = false
    var target = Target.phone
    /// A handoff to the phone was asked for and hasn't arrived yet.
    var handingOff = false
    let local = LocalPlayer()

    private(set) var macState = LinkState.empty
    private(set) var macQueue = LinkQueue.empty
    /// When `macState` arrived; its position is worked out from here.
    @ObservationIgnored private var macStateAt = Date()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var link: LinkConnection?
    @ObservationIgnored private var retrying = false

    init() {
        local.onChange = { [weak self] in self?.reportLocal() }
        macName = UserDefaults.standard.string(forKey: "macName")
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

    /// A song picked in Home, Search or Library plays wherever playback is now.
    func play(_ songs: [Song], at i: Int) {
        let list = songs.map(\.link)
        if target == .mac, connected {
            link?.send(.command(.play(list, i)))
        } else {
            target = .phone
            local.play(list, at: i)
        }
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
        guard connected else { return }
        if local.current != nil {
            link?.send(.handoff(local.handoff))
        }
        // Switched first, so the pause isn't reported back as something still to resume.
        target = .mac
        local.pause()
    }

    // MARK: Connection

    /// Hosts to try when Bonjour finds nothing: one typed in Settings, then the
    /// Tailscale addresses the Mac sent last time.
    private var savedHosts: [String] {
        let typed = UserDefaults.standard.string(forKey: "macHost").map { [$0] } ?? []
        return (typed + (UserDefaults.standard.stringArray(forKey: "macHosts") ?? [])).filter { !$0.isEmpty }
    }

    /// Called when the app comes to the front; a no-op while connected.
    func start() {
        guard link == nil else { return }
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: Link.controlService, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
        browser.start(queue: .main)
        self.browser = browser
        retry()
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard !connected, let result = results.first(where: { Self.name(of: $0) == macName }) ?? results.first,
              let name = Self.name(of: result) else { return }
        open(result.endpoint, name: name,
             audio: .service(name: name, type: Link.audioService, domain: "local.", interface: nil))
    }

    /// Bonjour first; with nothing on this network, the saved address. Repeats
    /// while disconnected, a small TCP attempt every few seconds.
    private func retry() {
        guard !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.retrying = false
            guard !self.connected else { return }
            if let results = self.browser?.browseResults, !results.isEmpty {
                self.found(results)
            } else if let host = self.savedHosts.first {
                self.open(.hostPort(host: .init(host), port: .init(rawValue: Link.controlPort)!), name: self.macName ?? host,
                          audio: .hostPort(host: .init(host), port: .init(rawValue: Link.audioPort)!))
            }
            self.retry()
        }
    }

    private func open(_ endpoint: NWEndpoint, name: String, audio: NWEndpoint) {
        // An attempt at a Mac that has since gone can wait forever; the new one replaces it.
        if let pending = link {
            link = nil
            pending.cancel()
        }
        let link = LinkConnection(NWConnection(to: endpoint, using: LinkConnection.parameters))
        link.onReady = { [weak self, unowned link] in
            guard let self else { return }
            self.connected = true
            self.macName = name
            UserDefaults.standard.set(name, forKey: "macName")
            self.local.endpoint = audio
            link.send(.hello(name: UIDevice.current.name, hosts: []))
            self.reportLocal()
        }
        link.onMessage = { [weak self] in self?.handle($0) }
        link.onClose = { [weak self, unowned link] in
            guard let self, self.link === link else { return }
            self.link = nil
            self.connected = false
            self.handingOff = false
            self.local.endpoint = nil
            if self.target == .mac { self.target = .phone }
        }
        self.link = link
        link.start()
    }

    private static func name(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { name } else { nil }
    }

    private func handle(_ message: LinkMessage) {
        switch message {
        case .hello(_, let hosts):
            if !hosts.isEmpty { UserDefaults.standard.set(hosts, forKey: "macHosts") }
        case .state(let state):
            macState = state
            macStateAt = .now
            // Nothing playing here: show the Mac, like Spotify shows the active device.
            if local.current == nil, state.song != nil { target = .mac }
        case .queue(let queue):
            macQueue = queue
        case .handoff(let handoff):
            handingOff = false
            target = .phone
            local.volume = macState.volume
            local.take(handoff)
        case .handoffRequest:
            // "Resume Here" on the Mac.
            if target == .phone { continueOnMac() }
        case .command:
            break
        }
    }

    /// Tells the Mac what plays here, for its "Continue from iPhone" banner.
    private func reportLocal() {
        guard target == .phone else { return }
        link?.send(.state(local.state))
    }
}

extension Song {
    var link: LinkSong {
        LinkSong(id: id, title: title, artist: artist, album: album, duration: duration, artwork: artwork)
    }
}
