import AppKit
import MediaPlayer

/// Media keys, AirPods controls and the Now Playing widget in Control Center.
final class NowPlayingCenter {
    private var artworkSongID: String?
    private var artwork: MPMediaItemArtwork?

    init(player: Player) {
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
}
