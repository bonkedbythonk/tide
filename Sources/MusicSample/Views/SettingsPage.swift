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
                    Toggle("Autoplay similar songs", isOn: $player.autoplay)
                    Toggle("Smooth transitions", isOn: $player.smoothTransitions)
                    Toggle("Match YouTube Music loudness", isOn: $player.matchLoudness)
                    Picker("Video quality", selection: $player.videoQuality) {
                        ForEach([480, 720, 1080, 1440, 2160], id: \.self) { Text("\($0)p").tag($0) }
                    }
                }
                WallpaperSettings()
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
