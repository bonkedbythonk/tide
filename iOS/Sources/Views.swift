import SwiftUI

struct NowPlayingScreen: View {
    @Environment(Remote.self) private var remote
    @State private var showQueue = false

    var body: some View {
        NavigationStack {
            Group {
                if let song = remote.state.song {
                    player(song)
                } else {
                    ContentUnavailableView("Nothing playing", systemImage: "music.note",
                                           description: Text("Pick something in Home, Search or Library."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { DeviceLabel() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showQueue = true } label: { Image(systemName: "list.bullet") }
                        .disabled(remote.queue.songs.isEmpty)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showQueue) { QueueSheet() }
        }
    }

    private func player(_ song: LinkSong) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Cover(url: song.artwork, pixels: 544)
                .frame(maxWidth: 340)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            VStack(spacing: 4) {
                Text(song.title).font(.title2.bold()).lineLimit(1)
                Text(song.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            Scrubber()
            Controls()
            VolumeSlider()
            if remote.target == .phone, let error = remote.local.error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            } else if remote.target == .phone, remote.local.embedded {
                Text("Playing through YouTube Music's web player because your Mac can't be reached.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }
}

/// Where the music is playing; tap to move it, like Spotify Connect.
struct DeviceLabel: View {
    @Environment(Remote.self) private var remote

    var body: some View {
        Menu {
            Button { if remote.target == .mac { remote.continueOnPhone() } } label: {
                Label("This iPhone", systemImage: remote.target == .phone ? "checkmark" : "iphone")
            }
            if remote.connected {
                Button { if remote.target == .phone { remote.continueOnMac() } } label: {
                    Label(remote.macName ?? "Mac", systemImage: remote.target == .mac ? "checkmark" : "desktopcomputer")
                }
            }
        } label: {
            HStack(spacing: 6) {
                if remote.handingOff {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: remote.target == .phone ? "iphone" : "desktopcomputer")
                }
                Text(remote.target == .phone ? "This iPhone" : remote.macName ?? "Mac")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
        }
        .tint(.primary)
    }
}

struct Scrubber: View {
    @Environment(Remote.self) private var remote
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(remote.state.duration, 1)
            let position = dragging ?? min(remote.position(at: context.date), duration)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { position }, set: { dragging = $0 }), in: 0...duration) { editing in
                    if !editing, let t = dragging {
                        remote.send(.seek(t))
                        dragging = nil
                    }
                }
                HStack {
                    Text(time(position))
                    Spacer()
                    Text("-" + time(duration - position))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func time(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct Controls: View {
    @Environment(Remote.self) private var remote

    var body: some View {
        HStack(spacing: 48) {
            Button { remote.send(.previous) } label: { Image(systemName: "backward.fill") }
            Button { remote.send(.toggle) } label: {
                if remote.target == .phone, remote.local.loading {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Image(systemName: remote.state.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
            }
            .font(.system(size: 44))
            Button { remote.send(.next) } label: { Image(systemName: "forward.fill") }
        }
        .font(.title)
        .buttonStyle(.plain)
        .disabled(remote.target == .mac && !remote.connected)
    }
}

struct VolumeSlider: View {
    @Environment(Remote.self) private var remote
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            // While dragging, the slider follows the finger, not the Mac's echoes.
            Slider(value: Binding(get: { dragging ?? remote.state.volume },
                                  set: { dragging = $0; remote.send(.volume($0)) }),
                   in: 0...1) { editing in if !editing { dragging = nil } }
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct QueueSheet: View {
    @Environment(Remote.self) private var remote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let queue = remote.queue
        let rows = Array(queue.songs.enumerated()).map { (index: queue.first + $0.offset, song: $0.element) }
        NavigationStack {
            List {
                Section("Now Playing") {
                    ForEach(rows.filter { $0.index == queue.index }, id: \.index) { row(song: $0.song, index: $0.index) }
                }
                Section("Up Next") {
                    ForEach(rows.filter { $0.index > queue.index }, id: \.index) { row(song: $0.song, index: $0.index) }
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func row(song: LinkSong, index: Int) -> some View {
        Button { remote.send(.jump(index)) } label: {
            HStack(spacing: 12) {
                Cover(url: song.artwork, pixels: 120).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).lineLimit(1)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .tint(.primary)
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dataSaver") private var dataSaver = false
    @State private var downloaded = AudioFiles.size
    @AppStorage("macHost") private var macHost = ""
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Data Saver", isOn: $dataSaver)
                } footer: {
                    Text("Plays songs at about 48 kbps instead of 128. The next song is only fetched ahead on Wi-Fi, never on cellular or in Low Data Mode. Videos are never downloaded.")
                }
                Section {
                    TextField("Mac address", text: $macHost, prompt: Text(UserDefaults.standard.stringArray(forKey: "macHosts")?.first ?? "100.x.y.z"))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Away from home")
                } footer: {
                    Text("With Tailscale on your Mac and iPhone, songs keep coming from your Mac anywhere. Tide fills in your Mac's Tailscale address the first time they meet on Wi-Fi; type one here to use another.")
                }
                Section {
                    LabeledContent("Downloaded songs", value: ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file))
                    Button("Remove Downloads", role: .destructive) {
                        AudioFiles.clear()
                        downloaded = AudioFiles.size
                    }
                } footer: {
                    Text("Songs played on the iPhone are kept, so playing them again uses no data.")
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await library.signOut() }
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Album art at the size it's shown, kept on disk so it's only downloaded once.
struct Cover: View {
    let url: URL?
    let pixels: Int
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.title).foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: pixels > 200 ? 12 : 6))
            .task(id: url) {
                image = nil
                guard let url else { return }
                var request = URLRequest(url: Self.sized(url, pixels))
                request.cachePolicy = .returnCacheDataElseLoad
                if let (data, _) = try? await URLSession.shared.data(for: request) { image = UIImage(data: data) }
            }
    }

    /// YouTube Music covers take their size in the URL; video thumbnails come in fixed sizes.
    static func sized(_ url: URL, _ pixels: Int) -> URL {
        var s = url.absoluteString
        if let r = s.range(of: #"=w\d+-h\d+.*$"#, options: .regularExpression) {
            s.replaceSubrange(r, with: "=w\(pixels)-h\(pixels)-l90-rj")
        } else if url.host()?.hasSuffix("ytimg.com") == true {
            s = url.deletingLastPathComponent().appendingPathComponent(pixels > 200 ? "hqdefault.jpg" : "mqdefault.jpg").absoluteString
        }
        return URL(string: s) ?? url
    }
}
