import SwiftUI

struct NowPlayingScreen: View {
    @Environment(Remote.self) private var remote
    @State private var showQueue = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let song = remote.state.song {
                    player(song)
                } else {
                    ContentUnavailableView(remote.connected ? "Nothing playing" : "Looking for your Mac",
                                           systemImage: "desktopcomputer",
                                           description: Text(remote.connected
                                               ? "Play something in Tide on \(remote.macName ?? "your Mac")."
                                               : "Open Tide on a Mac on the same Wi-Fi."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .principal) { DeviceLabel() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showQueue = true } label: { Image(systemName: "list.bullet") }
                        .disabled(remote.queue.songs.isEmpty)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showQueue) { QueueSheet() }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
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
            HandoffButton()
            if let error = remote.target == .phone ? remote.local.error : nil {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }
}

/// Where the music is playing.
struct DeviceLabel: View {
    @Environment(Remote.self) private var remote

    var body: some View {
        HStack(spacing: 6) {
            if remote.target == .phone {
                Image(systemName: "iphone")
                Text("This iPhone")
            } else {
                Image(systemName: "desktopcomputer")
                Text(remote.macName ?? "Mac")
                if !remote.connected { ProgressView().controlSize(.mini) }
            }
        }
        .font(.subheadline.weight(.semibold))
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

struct HandoffButton: View {
    @Environment(Remote.self) private var remote

    var body: some View {
        if remote.target == .phone {
            Button { remote.continueOnMac() } label: {
                Label("Continue on \(remote.macName ?? "Mac")", systemImage: "desktopcomputer")
            }
            .buttonStyle(.bordered)
            .disabled(!remote.connected)
        } else {
            Button { remote.continueOnPhone() } label: {
                if remote.handingOff {
                    ProgressView()
                } else {
                    Label("Continue on iPhone", systemImage: "iphone")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!remote.connected || remote.handingOff)
        }
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Data Saver", isOn: $dataSaver)
                } footer: {
                    Text("Plays songs at about 48 kbps instead of 128. Audio comes from your Mac over Wi-Fi and the next song is only fetched ahead on Wi-Fi, never on cellular or in Low Data Mode. Videos are never downloaded.")
                }
                Section {
                    LabeledContent("Downloaded songs", value: ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file))
                    Button("Remove Downloads", role: .destructive) {
                        AudioFiles.clear()
                        downloaded = AudioFiles.size
                    }
                } footer: {
                    Text("Songs you continue on iPhone are kept so they play again away from your Mac.")
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
