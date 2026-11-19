import Foundation
import Network

/// Finds Tide on a Mac over the home network and asks it for everything: the
/// library, search, lyrics and the songs themselves.
@MainActor @Observable final class MacLink {
    struct Found: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum State: Equatable { case searching, connecting, connected, failed(String) }

    var state = State.searching
    var found: [Found] = []
    private(set) var macName = ""

    /// http://host:port of the paired Mac, once connected.
    @ObservationIgnored private var base: URL?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var reconnecting: Task<Bool, Never>?
    @ObservationIgnored private var code = UserDefaults.standard.string(forKey: "code") ?? ""
    @ObservationIgnored private var pairedName = UserDefaults.standard.string(forKey: "mac")

    var hasCode: Bool { !code.isEmpty }

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: TVProtocol.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Found? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                return Found(name: name, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                self.found = found
                // The Mac paired last time reconnects by itself.
                if self.state == .searching, self.hasCode, let mac = found.first(where: { $0.name == self.pairedName }) {
                    await self.connect(mac, code: self.code)
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Resolves the Mac's address, then checks the code with it.
    func connect(_ mac: Found, code: String) async {
        state = .connecting
        guard let address = await Self.resolve(mac.endpoint) else {
            state = .failed("Couldn't reach \(mac.name)")
            return
        }
        base = URL(string: "http://\(address)")
        self.code = code
        do {
            let hello: TVProtocol.Hello = try await get("hello")
            macName = hello.name
            UserDefaults.standard.set(code, forKey: "code")
            UserDefaults.standard.set(mac.name, forKey: "mac")
            pairedName = mac.name
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: "code")
        UserDefaults.standard.removeObject(forKey: "mac")
        code = ""
        pairedName = nil
        state = .searching
    }

    /// The service's IPv4 address and port as "a.b.c.d:port", which URLs and AVPlayer take as is.
    private static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: params)
        return await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ value: String?) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        finish("\(text):\(port.rawValue)")
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(nil) }
        }
    }

    // MARK: Requests

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        guard let base, var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        parts.queryItems = query + [URLQueryItem(name: "k", value: code)]
        return parts.url
    }

    /// Looks the paired Mac up again: Tide gets a new port each time it starts.
    func reconnect() async -> Bool {
        if let running = reconnecting { return await running.value }
        let task = Task { () -> Bool in
            guard let mac = found.first(where: { $0.name == pairedName }),
                  let address = await Self.resolve(mac.endpoint) else { return false }
            base = URL(string: "http://\(address)")
            return true
        }
        reconnecting = task
        defer { reconnecting = nil }
        return await task.value
    }

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        guard let url = url(path, query) else { throw Failure(errorDescription: "Not connected") }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch let error as URLError where [.cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost].contains(error.code) {
            // Tide on the Mac restarted (new port) or the network blinked: find it and try once more.
            guard await reconnect(), let again = self.url(path, query) else { throw error }
            (data, response) = try await URLSession.shared.data(from: again)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(errorDescription: String(decoding: data, as: UTF8.self).isEmpty
                          ? "The Mac answered \(status)" : String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func audioURL(_ videoId: String) -> URL? { url("audio/" + videoId) }
    /// The music video with the song's sound, as one file.
    func videoURL(_ videoId: String) -> URL? { url("video/" + videoId) }

    /// Has the Mac look the song up now, so skipping to it starts quickly.
    func warm(_ videoId: String, video: Bool = false) {
        guard let url = video ? videoURL(videoId) : audioURL(videoId) else { return }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: request).resume()
    }
}
