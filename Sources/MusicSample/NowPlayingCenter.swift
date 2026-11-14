import AppKit
import MediaPlayer

/// Media keys, AirPods controls and the Now Playing widget in Control Center.
/// Also broadcasts the current song over distributed notifications (title,
/// artist, cover, position, current and next lyric line, up next queue,
/// liked, volume, shuffle) and takes commands from them (play/pause, next,
/// previous, like, seek, volume, shuffle), for companion
/// apps like DockWings (other apps can't read the system Now Playing info any
/// more). Position is sent with a timestamp every few seconds; listeners
/// interpolate between broadcasts.
///
/// DockWings protocol. Commands arrive on "local.tide.command" as the notification's
/// object string; everything posted carries a property-list userInfo.
///   playpause, next, previous, state, like, shuffle, seek:<0..1>, volume:<0..1>
///   play:<n>            play the n-th song of Up Next now (0-based)
///   move:<from>:<to>    move an Up Next song from index <from> to end up at index <to>
///   search:<query>      songs search, answered on "local.tide.results"
///   playid:<songId>     play a song from the last search results now
///   radio               radio from the current song (replaces Up Next, like Tide's Start radio)
///   mood:<text>         replace Up Next with a mood, like typing it in the mood box
///   playlists           answered on "local.tide.playlists"
///   addto:<playlistId>  add the current song to that playlist
///   lyrics              re-post "local.tide.lyrics"
/// Posted by Tide:
///   local.tide.nowPlaying  {title, artist, artwork, playing, position, duration, sentAt, lyric,
///                           lyricNext, liked, next, queue, queueArt, volume, shuffle,
///                           mixAt (seconds into the song where the next one mixes in, -1 if none),
///                           mixBegan (epoch seconds a smart-transition mix began, 0 if none), mixSeconds}
///   local.tide.results     {query, ids, titles, artists, artworks}  (up to 8 songs)
///   local.tide.playlists   {ids, names}
///   local.tide.lyrics      {songId, times, lines}  (empty arrays without synced lyrics); posted
///                          when the song changes, when its lyrics load, and on "lyrics"
///   local.tide.levels      {levels: [5 x 0...1]}  about 15 times a second while playing. These
///                          are one loudness reading (EBU R128 momentary, from mpv) with five
///                          different smoothings, not frequency bands.
final class NowPlayingCenter {
    private var artworkSongID: String?
    private var artwork: MPMediaItemArtwork?
    private var broadcastInfo: [String: Any] = [:]
    private var broadcastKey = ""
    private var lastBroadcast = Date.distantPast
    private var lyricsKey = ""
    private var lastResults: [Song] = []
    private var levelTimer: Timer?
    private var bars = [Double](repeating: 0, count: 5)

    /// Set once by the app so broadcasts can include lyrics and likes.
    static weak var lyrics: LyricsStore?
    static weak var library: Library?

    private static let stateName = Notification.Name("local.tide.nowPlaying")
    private static let commandName = Notification.Name("local.tide.command")
    private static let resultsName = Notification.Name("local.tide.results")
    private static let playlistsName = Notification.Name("local.tide.playlists")
    private static let lyricsName = Notification.Name("local.tide.lyrics")
    private static let levelsName = Notification.Name("local.tide.levels")

    init(player: Player) {
        DistributedNotificationCenter.default().addObserver(forName: Self.commandName, object: nil, queue: .main) { [weak self, weak player] note in
            let command = note.object as? String ?? ""
            switch command {
            case "playpause": player?.toggle()
            case "next": player?.next()
            case "previous": player?.previous()
            case "state": self?.broadcast()
            case "like":
                if let id = player?.current?.id { Self.library?.toggleLike(id) }
                self?.broadcastKey = ""
            case "shuffle":
                player?.shuffle.toggle()
                self?.broadcastKey = ""
            default:
                // "seek:0.42" jumps to that fraction of the song.
                if command.hasPrefix("seek:"), let fraction = Double(command.dropFirst(5)), let player, player.length > 0 {
                    player.seek(fraction * player.length)
                } else if command.hasPrefix("volume:"), let level = Double(command.dropFirst(7)), let player {
                    // "volume:0.6" sets the volume (0...1).
                    player.volume = min(max(level, 0), 1)
                    self?.broadcastKey = ""
                } else if let player {
                    self?.handleExtended(command, player: player)
                }
            }
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self, weak player] _ in
            guard let self, let player, player.isPlaying else { return }
            self.postLevels(player.engine.loudness())
        }

        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak player] _ in
            player?.toggle()
            return .success
        }
        commands.playCommand.addTarget { [weak player] _ in
            if player?.isPlaying == false { player?.toggle() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak player] _ in
            if player?.isPlaying == true { player?.toggle() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak player] _ in
            player?.next()
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak player] _ in
            player?.previous()
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player?.seek(event.positionTime)
            return .success
        }
    }

    func update(song: Song?, position: TimeInterval, duration: TimeInterval, playing: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        let lines = song.map { Self.lyricLines(for: $0.id, at: position) } ?? ("", "")
        let lyric = lines.0
        let liked = song.map { Self.library?.liked.contains($0.id) ?? false } ?? false
        let key = song.map { "\($0.id)|\(playing)|\(lyric)|\(liked)|\(queue)|\(volume)|\(shuffle)|\(mixAt.map { Int($0) } ?? -1)|\(mixBegan?.timeIntervalSince1970 ?? 0)" } ?? ""
        postLyricsIfChanged(for: song)
        if key != broadcastKey || (playing && Date().timeIntervalSince(lastBroadcast) > 5) {
            broadcastKey = key
            broadcastInfo = song.map {
                ["title": $0.title, "artist": $0.artist, "artwork": $0.artwork?.absoluteString ?? "", "playing": playing,
                 "position": position, "duration": duration, "sentAt": Date().timeIntervalSince1970,
                 "lyric": lyric, "lyricNext": lines.1, "liked": liked, "next": nextTitle ?? "",
                 "queue": queue, "queueArt": queueArt, "volume": volume, "shuffle": shuffle,
                 "mixAt": mixAt ?? -1, "mixBegan": mixBegan?.timeIntervalSince1970 ?? 0, "mixSeconds": mixSeconds]
            } ?? [:]
            broadcast()
        }
        guard let song else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        if song.id != artworkSongID {
            artworkSongID = song.id
            artwork = nil
            if let url = song.artwork {
                Task { @MainActor [weak self] in
                    guard let image = await ImageDecodeCache.shared.image(url, maxPixelSize: 600),
                          let self, self.artworkSongID == song.id else { return }
                    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.artwork = MPMediaItemArtwork(boundsSize: nsImage.size) { _ in nsImage }
                    center.nowPlayingInfo?[MPMediaItemPropertyArtwork] = self.artwork
                }
            }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }

    /// "Title · Artist" of the next song in the queue, set by Player.
    var nextTitle: String?
    /// The next few songs, one "Title · Artist" per line, set by Player.
    var queue = ""
    /// Cover URLs for those songs, one per line (empty when unknown).
    var queueArt = ""
    var volume = 0.0
    var shuffle = false
    /// Smart transitions, for DockWings' bar: the planned mix point and the mix under way.
    var mixAt: TimeInterval?
    var mixBegan: Date?
    var mixSeconds = 0.0

    /// The current synced lyric line and the one after it.
    private static func lyricLines(for songID: String, at position: TimeInterval) -> (String, String) {
        guard case .synced(let lines) = lyrics?.result(for: songID) else { return ("", "") }
        guard let index = lines.lastIndex(where: { $0.time <= position + 0.2 }) else { return ("", lines.first?.text ?? "") }
        return (lines[index].text, lines.indices.contains(index + 1) ? lines[index + 1].text : "")
    }

    private func handleExtended(_ command: String, player: Player) {
        let parts = command.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let upNext = player.upNext
        switch parts[0] {
        case "play":
            if parts.count == 2, let n = Int(parts[1]), upNext.indices.contains(n) { player.jump(to: player.index + 1 + n) }
        case "move":
            if parts.count == 3, let from = Int(parts[1]), let to = Int(parts[2]),
               upNext.indices.contains(from), upNext.indices.contains(to), from != to {
                // moveUpNext takes an insertion offset, so moving down needs one more.
                player.moveUpNext(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
                broadcastKey = ""
            }
        case "search":
            let query = command.dropFirst("search:".count).trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty, let library = Self.library else { return }
            Task { @MainActor [weak self] in
                guard let json = try? await library.client.search(query, params: SearchKind.songs.rawValue) else { return }
                let songs = Array(YTParse.search(json).songs.prefix(8))
                self?.lastResults = songs
                DistributedNotificationCenter.default().postNotificationName(
                    Self.resultsName, object: nil,
                    userInfo: ["query": query, "ids": songs.map(\.id), "titles": songs.map(\.title),
                               "artists": songs.map(\.artist), "artworks": songs.map { $0.artwork?.absoluteString ?? "" }],
                    deliverImmediately: true)
            }
        case "playid":
            let id = command.dropFirst("playid:".count)
            if let song = lastResults.first(where: { $0.id == id }) { player.play(song, in: [song]) }
        case "radio":
            if let song = player.current { player.playRadio(song) }
        case "mood":
            player.startMood(String(command.dropFirst("mood:".count)))
        case "playlists":
            guard let library = Self.library else { return }
            // A playlist's page says whether it is yours; one not opened yet counts as editable.
            let own = library.playlists.filter { library.pages[$0.id]?.owned != false }
            DistributedNotificationCenter.default().postNotificationName(
                Self.playlistsName, object: nil,
                userInfo: ["ids": own.map(\.id), "names": own.map(\.title)], deliverImmediately: true)
        case "addto":
            guard let library = Self.library, let song = player.current else { return }
            // Remembers the song so the library can find it by id.
            _ = library.dragPayload([song])
            library.add([song.id], to: String(command.dropFirst("addto:".count)))
        case "lyrics":
            postLyrics(for: player.current)
        default: break
        }
    }

    /// Posts the lyrics when the song changes or its lyrics arrive.
    private func postLyricsIfChanged(for song: Song?) {
        let state = song.flatMap { Self.lyrics?.result(for: $0.id) }
        let kind = switch state {
        case .synced(let lines): "synced\(lines.count)"
        case nil: "unloaded"
        default: "other"
        }
        let key = (song?.id ?? "") + "|" + kind
        guard key != lyricsKey else { return }
        lyricsKey = key
        postLyrics(for: song)
    }

    private func postLyrics(for song: Song?) {
        guard let song else { return }
        var lines: [LyricLine] = []
        if case .synced(let synced) = Self.lyrics?.result(for: song.id) { lines = synced }
        DistributedNotificationCenter.default().postNotificationName(
            Self.lyricsName, object: nil,
            userInfo: ["songId": song.id, "times": lines.map(\.time), "lines": lines.map(\.text)],
            deliverImmediately: true)
    }

    /// Five bars from one loudness reading (LUFS): the same level with a fast, a medium and
    /// slow release and a couple of response curves, so they move a little differently.
    private func postLevels(_ lufs: Double?) {
        guard let lufs else { return }
        let level = min(max((lufs + 45) / 37, 0), 1)
        let release = [0.5, 0.35, 0.25, 0.15, 0.08]
        let curve = [1.0, 0.8, 1.2, 1.5, 0.65]
        for i in bars.indices {
            bars[i] = level > bars[i] ? bars[i] + (level - bars[i]) * 0.7 : bars[i] + (level - bars[i]) * release[i]
        }
        let shaped = bars.indices.map { min(max(pow(bars[$0], curve[$0]), 0), 1) }
        DistributedNotificationCenter.default().postNotificationName(
            Self.levelsName, object: nil, userInfo: ["levels": shaped], deliverImmediately: true)
    }

    private func broadcast() {
        lastBroadcast = Date()
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateName, object: nil, userInfo: broadcastInfo, deliverImmediately: true)
    }
}
