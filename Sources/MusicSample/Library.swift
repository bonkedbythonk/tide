import SwiftUI

/// The signed-in user's YouTube Music data. Reads are live; likes and playlist
/// additions are kept locally for now and not sent to YouTube.
@Observable final class Library {
    enum State: Equatable { case starting, signedOut, loading, ready, failed(String) }

    var state = State.starting
    var home: [HomeShelf] = []
    var playlists: [MediaItem] = []
    var savedAlbums: [MediaItem] = []
    var pages: [String: PageData] = [:]
    var liked: Set<String> = []
    var localAdds: [String: [Song]] = [:]
    var lastUsedPlaylistID: String?
    var toast: String?

    @ObservationIgnored let client = YTClient()
    @ObservationIgnored private var songIndex: [String: Song] = [:]
    @ObservationIgnored private var homeContinuation: String?
    @ObservationIgnored private var loadingHome = false
    @ObservationIgnored private var loadingPages: Set<String> = []
    /// Pages fetched fresh this session; others may still be showing the disk copy.
    @ObservationIgnored private var freshPages: Set<String> = []

    private struct Snapshot: Codable {
        let home: [HomeShelf]
        let playlists: [MediaItem]
        let savedAlbums: [MediaItem]
    }
    @ObservationIgnored private var toastToken = 0

    static let likedID = "VLLM"

    @MainActor
    func start() async {
        guard await client.loadCookies() else {
            state = .signedOut
            return
        }
        StreamResolver.cookieFile = await YTClient.writeCookieFile()
        // Last session's library shows at once; the refresh below replaces it.
        if let snapshot = DiskCache.load(Snapshot.self, "library") {
            home = snapshot.home
            playlists = snapshot.playlists
            savedAlbums = snapshot.savedAlbums
            home.forEach { $0.songs.forEach(remember) }
            if let likedPage = DiskCache.load(PageData.self, "page2-" + Self.likedID) {
                liked = Set(likedPage.songs.map(\.id))
            }
            state = .ready
        } else {
            state = .loading
        }
        await refresh()
    }

    @MainActor
    func refresh() async {
        if home.isEmpty { state = .loading }
        freshPages = []
        do {
            async let homeJSON = client.browse("FEmusic_home")
            async let playlistJSON = client.browse("FEmusic_liked_playlists")
            async let albumJSON = client.browse("FEmusic_liked_albums")
            let h = try await homeJSON
            home = YTParse.shelves(h)
            homeContinuation = YTParse.continuation(h)
            playlists = YTParse.cards(try await playlistJSON)
                .filter { $0.id.hasPrefix("VL") && $0.id != Self.likedID && $0.id != "VLSE" }
            savedAlbums = YTParse.cards(try await albumJSON).filter { $0.kind == .album }
            home.forEach { $0.songs.forEach(remember) }
            state = .ready
            await loadMoreHome(pages: 3)
            DiskCache.save(Snapshot(home: home, playlists: playlists, savedAlbums: savedAlbums), "library")
            if let likedPage = await page(Self.likedID) { liked = Set(likedPage.songs.map(\.id)) }
        } catch {
            // With a cached library on screen, a failed refresh just leaves it there.
            if home.isEmpty { state = .failed(error.localizedDescription) }
        }
    }

    /// YouTube sends Home a few sections at a time.
    @MainActor
    func loadMoreHome(pages: Int) async {
        guard !loadingHome else { return }
        loadingHome = true
        defer { loadingHome = false }
        for _ in 0..<pages {
            guard let token = homeContinuation,
                  let json = try? await client.more(token, homeStyle: true) else { return }
            let more = YTParse.shelves(json).filter { s in !home.contains { $0.title == s.title } }
            more.forEach { $0.songs.forEach(remember) }
            home += more
            homeContinuation = YTParse.continuation(json)
        }
    }

    /// A playlist, album, mix or artist page, with every song (up to 2,000).
    @MainActor
    func page(_ id: String) async -> PageData? {
        if pages[id] == nil, let cached = DiskCache.load(PageData.self, "page2-" + id) {
            cached.songs.forEach(remember)
            pages[id] = cached
        }
        if freshPages.contains(id) { return pages[id] }
        guard !loadingPages.contains(id) else { return pages[id] }
        loadingPages.insert(id)
        defer { loadingPages.remove(id) }
        // With a disk copy on screen, swap in the fresh list only once it's complete,
        // so a long playlist doesn't shrink to its first 100 songs and grow back.
        let showProgress = pages[id] == nil
        do {
            let json = try await client.browse(id)
            let parsed = YTParse.page(json, id: id)
            var data = parsed.data
            if showProgress { pages[id] = data }
            var token = parsed.more
            while let t = token, data.songs.count < 2000 {
                let next = try await client.more(t)
                let more = YTParse.songs(next)
                guard !more.isEmpty else { break }
                data.songs += more
                if showProgress { pages[id] = data }
                token = YTParse.continuation(next)
            }
            if data.suggestions?.isEmpty != false, let t = parsed.suggestions,
               let next = try? await client.more(t) {
                data.suggestions = YTParse.songs(next)
            }
            data.songs.forEach(remember)
            data.suggestions?.forEach(remember)
            pages[id] = data
            freshPages.insert(id)
            DiskCache.save(data, "page2-" + id)
            if id == Self.likedID { liked = Set(data.songs.map(\.id)) }
            return data
        } catch {
            if pages[id] == nil { showToast("Couldn't load: \(error.localizedDescription)") }
            return pages[id]
        }
    }

    func songs(in pageID: String) -> [Song] {
        (pages[pageID]?.songs ?? []) + (localAdds[pageID] ?? [])
    }

    @MainActor
    func search(_ query: String) async -> (songs: [Song], items: [MediaItem]) {
        guard let json = try? await client.search(query) else { return ([], []) }
        let result = YTParse.search(json)
        result.songs.forEach(remember)
        return result
    }

    @MainActor
    func signOut() async {
        await YTClient.signOut()
        DiskCache.clear()
        freshPages = []
        home = []
        playlists = []
        savedAlbums = []
        pages = [:]
        liked = []
        state = .signedOut
    }

    private func remember(_ s: Song) { songIndex[s.id] = s }
    func song(_ id: String) -> Song? { songIndex[id] }
    var knownSongs: Dictionary<String, Song>.Values { songIndex.values }
    func songs(_ ids: [String]) -> [Song] { ids.compactMap { songIndex[$0] } }
    func playlist(_ id: String) -> MediaItem? { playlists.first { $0.id == id } }

    func isLiked(_ id: String) -> Bool { liked.contains(id) }

    func toggleLike(_ id: String) {
        if liked.remove(id) != nil {
            showToast("Removed from Liked Songs (this Mac only for now)")
        } else {
            liked.insert(id)
            showToast("Liked (this Mac only for now)")
        }
    }

    func like(_ ids: [String]) {
        liked.formUnion(ids)
        showToast(ids.count == 1 ? "Liked (this Mac only for now)" : "Liked \(ids.count) songs (this Mac only for now)")
    }

    func contains(_ ids: [String], in playlistID: String) -> Bool {
        let present = Set(songs(in: playlistID).map(\.id))
        return ids.allSatisfy(present.contains)
    }

    func add(_ ids: [String], to playlistID: String) {
        let present = Set(songs(in: playlistID).map(\.id))
        let new = songs(ids).filter { !present.contains($0.id) }
        localAdds[playlistID, default: []] += new
        lastUsedPlaylistID = playlistID
        let name = playlist(playlistID)?.title ?? "playlist"
        if new.isEmpty {
            showToast("Already in \(name)")
        } else {
            showToast((new.count == 1 ? "Added to \(name)" : "Added \(new.count) songs to \(name)") + " (this Mac only for now)")
        }
    }

    func remove(_ ids: [String], from playlistID: String) {
        localAdds[playlistID]?.removeAll { ids.contains($0.id) }
        pages[playlistID]?.songs.removeAll { ids.contains($0.id) }
        showToast("Removed (this Mac only for now)")
    }

    func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.snappy) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.toastToken == token else { return }
            withAnimation(.snappy) { self.toast = nil }
        }
    }
}
