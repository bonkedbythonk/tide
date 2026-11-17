import SwiftUI

/// Every setting in one page of the main window (⌘, or the gear in the sidebar).
struct SettingsPage: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var player = player
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 30, weight: .bold))
                .padding(.horizontal, 24)
                .padding(.top, 50)
            Form {
                Section("Playback") {
                    LabeledContent("Crossfade") {
                        HStack {
                            Slider(value: $player.crossfade, in: 0...12, step: 1)
                            Text(player.crossfade == 0 ? "Off" : "\(Int(player.crossfade)) s")
                                .monospacedDigit().frame(width: 34, alignment: .trailing)
                        }
                    }
                    .disabled(player.smartTransitions)
                    .help(player.smartTransitions ? "Smart transitions choose the crossfade" : "")
                    Toggle("Autoplay similar songs", isOn: $player.autoplay)
                    Toggle("Smooth transitions", isOn: $player.smoothTransitions)
                    Toggle("Match YouTube Music loudness", isOn: $player.matchLoudness)
                    Toggle("Show what's playing on Discord", isOn: $player.discordPresence)
                    Toggle("Add songs you play to your YouTube history", isOn: $player.addToHistory)
                    Picker("Video quality", selection: $player.videoQuality) {
                        ForEach([480, 720, 1080, 1440, 2160], id: \.self) { Text("\($0)p").tag($0) }
                    }
                }
                WallpaperSettings()
                SpotifySyncSettings()
                AppleTVSettings()
                Section("Account") {
                    LabeledContent("Library") {
                        Button("Refresh") { Task { await library.refresh() } }
                    }
                    LabeledContent("YouTube Music") {
                        Button("Sign Out") { Task { await library.signOut() } }
                    }
                }
                Section("Help") {
                    LabeledContent("Keyboard shortcuts") {
                        Button("Show") { router.showShortcuts = true }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Tide on Apple TV plays through this Mac while this is on.
private struct AppleTVSettings: View {
    @Environment(TVServer.self) private var server

    var body: some View {
        @Bindable var server = server
        Section {
            Toggle("Let Tide on Apple TV play through this Mac", isOn: $server.enabled)
            if server.enabled {
                LabeledContent("Pairing code") {
                    Text(server.code).font(.body.monospacedDigit()).textSelection(.enabled)
                }
            }
        } header: {
            Text("Apple TV")
        } footer: {
            Text(server.enabled
                 ? (server.status.isEmpty ? "Starting..." : server.status) + ". Enter the code on the TV the first time. Keep this Mac awake while you listen."
                 : "Apple TV uses this Mac's sign-in and yt-dlp, over your home network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Which playlists sync with Spotify. Songs added on either side are added on the other.
private struct SpotifySyncSettings: View {
    @Environment(SpotifySync.self) private var sync
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var sync = sync
        Section {
            if !sync.connected {
                TextField("Spotify app Client ID", text: $sync.clientID, prompt: Text("Paste it here"))
                LabeledContent("Spotify") {
                    Button("Connect") { Task { await sync.connect() } }
                        .disabled(sync.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                ForEach(sync.spotifyPlaylists, id: \.self) { playlist in
                    LabeledContent(playlist.name) {
                        HStack {
                            if let pair = sync.pair(spotify: playlist.id) {
                                Picker("YouTube Music playlist", selection: Binding(
                                    get: { pair.youtube },
                                    set: { sync.setPartner(spotify: playlist.id, youtube: $0) }
                                )) {
                                    Text("New playlist").tag("new")
                                    Text("Liked Music").tag(Library.likedID)
                                    ForEach(library.playlists) { Text($0.title).tag($0.id) }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            Toggle("Sync", isOn: Binding(
                                get: { sync.pair(spotify: playlist.id) != nil },
                                set: { sync.setSynced(playlist, $0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }
                }
                LabeledContent(sync.status.isEmpty ? "Sync" : sync.status) {
                    HStack {
                        Button("Sync Now") { Task { await sync.sync() } }
                            .disabled(sync.busy || sync.pairs.isEmpty)
                        Button("Disconnect") { sync.disconnect() }
                    }
                }
            }
        } header: {
            Text("Spotify sync")
        } footer: {
            Text(sync.connected
                 ? "Turn a Spotify playlist on and pick its YouTube Music partner. Songs added on either side are added to the other every 30 minutes while Tide is open. Removing a song never removes it from the other side."
                 : "Create an app at developer.spotify.com with the redirect URI \(SpotifySync.redirect) and Web API ticked, then paste its Client ID here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if sync.connected {
            Section("YouTube Music playlists to copy to Spotify") {
                let targets = Set(sync.pairs.filter { $0.spotify != "new" }.map(\.youtube))
                let liked = MediaItem(id: Library.likedID, title: "Liked Music", subtitle: "", artwork: nil, kind: .playlist)
                ForEach(([liked] + library.playlists).filter { !targets.contains($0.id) }) { playlist in
                    Toggle(playlist.title, isOn: Binding(
                        get: { sync.isSynced(youtube: playlist.id) },
                        set: { sync.setSynced(youtube: playlist, $0) }
                    ))
                }
            }
        }
    }
}
