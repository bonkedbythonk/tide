import SwiftUI

/// The signed-in user's YouTube Music data. Changes (likes, playlists, saves) show
/// at once and are sent to YouTube; one it refuses is put back.
@Observable final class Library {
    enum State: Equatable { case starting, signedOut, loading, ready, failed(String) }

    var state = State.starting
    var home: [HomeShelf] = []
    var playlists: [MediaItem] = []
    var savedAlbums: [MediaItem] = []
    var pages: [String: PageData] = [:]
    var liked: Set<String> = []
    var libraryArtists: [MediaItem] = []
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
    static let historyID = "FEmusic_history"
    /// Songs you added to your library (not the same as Liked Songs).
    static let librarySongsID = "FEmusic_liked_videos"

    @MainActor
    func start() async {
        if Demo.isOn {
            home = Demo.home
            playlists = Demo.playlists
            savedAlbums = Demo.savedAlbums
            pages = Demo.pages
            Demo.songs.forEach(remember)
            liked = Set(Demo.songs.prefix(10).map(\.id))
            state = .ready
            return
        }
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
        if Demo.isOn { return pages[id] }
        if pages[id] == nil, let cached = DiskCache.load(PageData.self, "page2-" + id) {
            cached.songs.forEach(remember)
            pages[id] = cached
        }
        // History changes as you listen, so it's fetched on every visit.
        if freshPages.contains(id), id != Self.historyID { return pages[id] }
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

    func songs(in pageID: String) -> [Song] { pages[pageID]?.songs ?? [] }

    /// Songs YouTube Music's Autoplay would play after `song`, without `song` itself.
    @MainActor
    func radio(after song: Song) async -> [Song] {
        guard let json = try? await client.radio(song.id) else { return [] }
        let songs = YTParse.radio(json).filter { $0.id != song.id }
        songs.forEach(remember)
        return songs
    }

    /// One shelf per kind of result, all asked for at once.
    @MainActor
    func search(_ query: String) async -> [HomeShelf] {
        let shelves = await withTaskGroup(of: (SearchKind, [ShelfItem]).self) { group in
            for kind in SearchKind.allCases {
                group.addTask { [client] in
                    guard let json = try? await client.search(query, params: kind.rawValue) else { return (kind, []) }
                    let result = YTParse.search(json)
                    let items: [ShelfItem] = switch kind {
                    case .songs: result.songs.map { .song($0, video: false) }
                    case .videos: result.songs.map { .song($0, video: true) }
                    default: result.items.map { .media($0) }
                    }
                    return (kind, items)
                }
            }
            var byKind: [SearchKind: [ShelfItem]] = [:]
            for await (kind, items) in group { byKind[kind] = items }
            return SearchKind.allCases.compactMap { kind in
                byKind[kind].flatMap { $0.isEmpty ? nil : HomeShelf(title: kind.title, items: $0) }
            }
        }
        shelves.forEach { $0.songs.forEach(remember) }
        return shelves
    }

    /// YouTube's suggestions for what you're typing, your own past searches among them.
    @MainActor
    func searchSuggestions(_ input: String) async -> [String] {
        guard !Demo.isOn else { return [] }
        var seen = Set<String>()
        return ((try? await client.searchSuggestions(input)) ?? []).filter { seen.insert($0.lowercased()).inserted }
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

    // MARK: Changes, sent to YouTube Music

    /// Playlist ids as YouTube's change requests take them, without "VL".
    static func plainID(_ id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }

    /// Sends a change that's already shown; if YouTube refuses it, `undo` puts things back.
    private func send(undo: @escaping () -> Void, _ work: @escaping () async throws -> Void) {
        guard !Demo.isOn else { return }
        Task { @MainActor in
            do {
                try await work()
            } catch {
                undo()
                showToast("Couldn't save to YouTube Music: \(error.localizedDescription)")
            }
        }
    }

    func toggleLike(_ id: String) {
        let on = !liked.contains(id)
        setLiked([id], on)
        showToast(on ? "Added to Liked Songs" : "Removed from Liked Songs")
    }

    func like(_ ids: [String]) {
        let new = ids.filter { !liked.contains($0) }
        setLiked(new, true)
        showToast(ids.count == 1 ? "Added to Liked Songs" : "Added \(ids.count) songs to Liked Songs")
    }

    private func setLiked(_ ids: [String], _ on: Bool) {
        guard !ids.isEmpty else { return }
        withAnimation(.snappy) {
            if on {
                liked.formUnion(ids)
                pages[Self.likedID]?.songs.insert(contentsOf: songs(ids), at: 0)
            } else {
                liked.subtract(ids)
                pages[Self.likedID]?.songs.removeAll { ids.contains($0.id) }
            }
        }
        send(undo: { [weak self] in
            if on { self?.liked.subtract(ids) } else { self?.liked.formUnion(ids) }
        }) { [client] in
            for id in ids { try await client.rate(on ? "like" : "removelike", videoId: id) }
        }
    }

    /// Tells YouTube you don't want this one, which steers recommendations and radios.
    func dislike(_ song: Song) {
        setLiked([song.id], false)
        showToast("Disliked: you'll hear less like this")
        send(undo: {}) { [client] in try await client.rate("dislike", videoId: song.id) }
    }

    func contains(_ ids: [String], in playlistID: String) -> Bool {
        let present = Set(songs(in: playlistID).map(\.id))
        return ids.allSatisfy(present.contains)
    }

    func add(_ ids: [String], to playlistID: String) {
        if playlistID == Self.likedID { return like(ids) }
        lastUsedPlaylistID = playlistID
        let name = playlist(playlistID)?.title ?? "playlist"
        Task { @MainActor in
            // Without the playlist loaded, songs already in it can't be skipped.
            if pages[playlistID] == nil { _ = await page(playlistID) }
            let present = Set(songs(in: playlistID).map(\.id))
            var seen = Set<String>()
            let new = Self.fresh(songs(ids).filter { !present.contains($0.id) && seen.insert($0.id).inserted })
            guard !new.isEmpty else { return showToast("Already in \(name)") }
            withAnimation(.snappy) { pages[playlistID]?.songs += new }
            showToast(new.count == 1 ? "Added to \(name)" : "Added \(new.count) songs to \(name)")
            send(undo: { [weak self] in
                self?.pages[playlistID]?.songs.removeAll { s in s.setVideoId == nil && new.contains { $0.id == s.id } }
            }) { [weak self] in try await self?.upload(new, to: playlistID) }
        }
    }

    /// Copies without the row id of the playlist they came from; the new playlist gives its own.
    private static func fresh(_ songs: [Song]) -> [Song] {
        songs.map { var s = $0; s.setVideoId = nil; return s }
    }

    /// Adds songs on YouTube, 100 at a time, and keeps each new row's id so the song
    /// can be removed again without reloading the playlist.
    @MainActor
    private func upload(_ songs: [Song], to playlistID: String) async throws {
        var rowIDs: [String: String] = [:]
        for start in stride(from: 0, to: songs.count, by: 100) {
            let chunk = songs[start..<min(start + 100, songs.count)]
            let results = try await client.editPlaylist(Self.plainID(playlistID),
                                                        chunk.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0.id] })
            for r in results {
                if let d = r["playlistEditVideoAddedResultData"] as? JSON, let v = d["videoId"] as? String,
                   let row = d["setVideoId"] as? String { rowIDs[v] = row }
            }
        }
        pages[playlistID]?.songs = pages[playlistID]?.songs.map { s in
            var s = s
            if s.setVideoId == nil { s.setVideoId = rowIDs[s.id] }
            return s
        } ?? []
        keep(playlistID)
    }

    func remove(_ ids: [String], from playlistID: String) {
        if playlistID == Self.likedID {
            setLiked(ids, false)
            return showToast("Removed from Liked Songs")
        }
        let rows = pages[playlistID]?.songs.filter { ids.contains($0.id) && $0.setVideoId != nil } ?? []
        guard !rows.isEmpty else { return showToast("Only your own playlists can be changed") }
        let before = pages[playlistID]?.songs
        withAnimation(.snappy) { pages[playlistID]?.songs.removeAll { ids.contains($0.id) } }
        showToast("Removed from \(playlist(playlistID)?.title ?? "playlist")")
        send(undo: { [weak self] in self?.pages[playlistID]?.songs = before ?? [] }) { [weak self, client] in
            try await client.editPlaylist(Self.plainID(playlistID), rows.map {
                ["action": "ACTION_REMOVE_VIDEO", "setVideoId": $0.setVideoId ?? "", "removedVideoId": $0.id]
            })
            await MainActor.run { self?.keep(playlistID) }
        }
    }

    /// A new private playlist, optionally filled with `songs`. Returns its browse id.
    @MainActor @discardableResult
    func createPlaylist(_ title: String, with songs: [Song] = []) async -> String? {
        guard !Demo.isOn else { return nil }
        do {
            let id = "VL" + (try await client.createPlaylist(title))
            var seen = Set<String>()
            let unique = Self.fresh(songs.filter { seen.insert($0.id).inserted })
            withAnimation(.snappy) {
                playlists.insert(MediaItem(id: id, title: title, subtitle: "Playlist", artwork: unique.first?.artwork,
                                           kind: .playlist), at: 0)
            }
            pages[id] = PageData(id: id, title: title, subtitle: "Playlist", artwork: unique.first?.artwork,
                                 songs: unique, owned: true)
            freshPages.insert(id)
            lastUsedPlaylistID = id
            if !unique.isEmpty { try await upload(unique, to: id) }
            showToast("Created \(title)")
            return id
        } catch {
            showToast("Couldn't create the playlist: \(error.localizedDescription)")
            return nil
        }
    }

    func renamePlaylist(_ id: String, to title: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let old = playlists[i]
        playlists[i] = MediaItem(id: id, title: title, subtitle: old.subtitle, artwork: old.artwork, kind: old.kind)
        pages[id]?.title = title
        send(undo: { [weak self] in
            if let j = self?.playlists.firstIndex(where: { $0.id == id }) { self?.playlists[j] = old }
            self?.pages[id]?.title = old.title
        }) { [weak self, client] in
            try await client.editPlaylist(Self.plainID(id), [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]])
            await MainActor.run { self?.keep(id) }
        }
    }

    func deletePlaylist(_ id: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let old = withAnimation(.snappy) { playlists.remove(at: i) }
        showToast("Deleted \(old.title)")
        send(undo: { [weak self] in
            guard let self, !self.playlists.contains(where: { $0.id == id }) else { return }
            self.playlists.insert(old, at: min(i, self.playlists.count))
        }) { [client] in
            try await client.deletePlaylist(Self.plainID(id))
        }
    }

    /// Saves an album or someone else's playlist to your library, or takes it out.
    func toggleSaved(_ pageID: String) {
        guard let page = pages[pageID], let saveID = page.saveID else { return }
        let on = !(page.saved ?? false)
        let item = MediaItem(id: page.id, title: page.title, subtitle: page.subtitle, artwork: page.artwork,
                             kind: pageID.hasPrefix("MPRE") ? .album : .playlist)
        func apply(_ on: Bool) {
            pages[pageID]?.saved = on
            if item.kind == .album {
                savedAlbums.removeAll { $0.id == pageID }
                if on { savedAlbums.insert(item, at: 0) }
            } else {
                playlists.removeAll { $0.id == pageID }
                if on { playlists.insert(item, at: 0) }
            }
        }
        withAnimation(.snappy) { apply(on) }
        showToast(on ? "Saved to your library" : "Removed from your library")
        send(undo: { apply(!on) }) { [client] in try await client.rate(on ? "like" : "removelike", playlistId: saveID) }
    }

    func toggleSubscribed(_ pageID: String) {
        guard let channelID = pages[pageID]?.channelID else { return }
        let on = !(pages[pageID]?.subscribed ?? false)
        withAnimation(.snappy) { pages[pageID]?.subscribed = on }
        send(undo: { [weak self] in self?.pages[pageID]?.subscribed = !on }) { [client] in
            try await client.subscribe(channelID, on)
        }
    }

    /// The page's or song's address on music.youtube.com, copied for sharing.
    func copyLink(_ id: String, song: Bool = false) {
        let path = song ? "watch?v=\(id)"
            : id.hasPrefix("VL") ? "playlist?list=\(Self.plainID(id))"
            : id.hasPrefix("UC") ? "channel/\(id)"
            : "browse/\(id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(YTClient.origin)/\(path)", forType: .string)
        showToast("Link copied")
    }

    /// Writes a changed page to disk, so the next launch doesn't show the old version.
    @MainActor
    private func keep(_ pageID: String) {
        if let page = pages[pageID] { DiskCache.save(page, "page2-" + pageID) }
    }

    /// Artists you listen to, from your library (the Library page's Artists tab).
    @MainActor
    func loadLibraryArtists() async {
        guard !Demo.isOn, let json = try? await client.browse("FEmusic_library_corpus_track_artists") else { return }
        var items = YTParse.search(json).items
        var token = YTParse.continuation(json)
        while let t = token, items.count < 1000, let next = try? await client.more(t) {
            items += YTParse.search(next).items
            token = YTParse.continuation(next)
        }
        // Library rows link to "MPLA" + the channel; the artist page is the channel itself.
        libraryArtists = items.map {
            MediaItem(id: $0.id.hasPrefix("MPLA") ? String($0.id.dropFirst(4)) : $0.id, title: $0.title,
                      subtitle: $0.subtitle, artwork: $0.artwork, kind: .artist)
        }
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
