import AppKit
import ImageIO
import SwiftUI

/// A wallpaper behind the app: off, the playing song's cover, your own image, or a
/// shuffle through one of Pinstill's boards (Pinstill downloads, crops and upscales
/// a Pinterest board into a folder; this only reads that folder).
@Observable final class WallpaperStore {
    enum Source: String, CaseIterable, Identifiable {
        case off, coverArt, pinstill, image
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: "None"
            case .coverArt: "Song's cover art"
            case .pinstill: "Pinstill board"
            case .image: "Your own image"
            }
        }
    }

    enum Shuffle: String, CaseIterable, Identifiable {
        case everySong, every5Minutes, every30Minutes, manual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everySong: "Every song"
            case .every5Minutes: "Every 5 minutes"
            case .every30Minutes: "Every 30 minutes"
            case .manual: "Only when I shuffle"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .every5Minutes: 300
            case .every30Minutes: 1800
            default: nil
            }
        }
    }

    struct Board: Identifiable, Hashable {
        let id: String
        let name: String
        let folder: URL
    }

    var source = Source(rawValue: Prefs.string("wallpaperSource") ?? "") ?? .off {
        didSet { Prefs.set(source.rawValue, "wallpaperSource"); refresh() }
    }
    var boardID = Prefs.string("wallpaperBoard") {
        didSet { Prefs.set(boardID ?? "", "wallpaperBoard"); refresh() }
    }
    var imagePath = Prefs.string("wallpaperImage") {
        didSet { Prefs.set(imagePath ?? "", "wallpaperImage"); refresh() }
    }
    // Changing on every track turns into flicker; a timer reads calmer.
    var shuffle = Shuffle(rawValue: Prefs.string("wallpaperShuffle") ?? "") ?? .every5Minutes {
        didSet { Prefs.set(shuffle.rawValue, "wallpaperShuffle"); restartTimer() }
    }
    /// One "how much of the picture shows" setting instead of separate blur and dim:
    /// 0 is a soft colour wash, 1 the image almost as is. Text stays readable across
    /// the range because the dim rises as the blur falls.
    var visibility = Prefs.double("wallpaperVisibility", 0.65) { didSet { Prefs.set(visibility, "wallpaperVisibility") } }

    /// Cover art is often low resolution, so it always shows as a wash.
    var blur: Double { source == .coverArt ? 70 : 80 * (1 - visibility) + 4 }
    var dim: Double { source == .coverArt ? 0.4 : 0.42 - 0.22 * visibility }

    private(set) var boards: [Board] = []
    /// The decoded image on screen now (nil = no wallpaper).
    private(set) var image: NSImage?
    private(set) var imageID = ""

    @ObservationIgnored private var coverURL: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadToken = 0

    var isActive: Bool { source != .off && image != nil }
    var selectedBoard: Board? { boards.first { $0.id == boardID } ?? boards.first }

    init() {
        loadBoards()
        refresh()
        restartTimer()
    }

    /// Reads the boards Pinstill follows from its own settings file.
    func loadBoards() {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/io.github.bonkedbythonk.pinstill.plist")
        struct Link: Decodable {
            struct B: Decodable { let id: String; let name: String }
            let board: B
            let folderPath: String
        }
        guard let data = try? Data(contentsOf: plist),
              let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let links = prefs["links"] as? Data,
              let decoded = try? JSONDecoder().decode([Link].self, from: links) else {
            boards = []
            return
        }
        boards = decoded.map { Board(id: $0.board.id, name: $0.board.name, folder: URL(filePath: $0.folderPath)) }
    }

    /// Called when the playing song changes.
    func songChanged(cover: URL?) {
        coverURL = cover
        switch source {
        case .coverArt: refresh()
        case .pinstill where shuffle == .everySong: shuffleNow()
        default: break
        }
    }

    func shuffleNow() {
        guard source == .pinstill, let board = selectedBoard else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: board.folder, includingPropertiesForKeys: nil)) ?? []
        let images = files.filter { ["jpg", "jpeg", "png", "heic", "webp"].contains($0.pathExtension.lowercased()) }
        let candidates = images.filter { $0.path != imageID }
        guard let pick = (candidates.isEmpty ? images : candidates).randomElement() else {
            show(nil)
            return
        }
        show(pick)
    }

    private func refresh() {
        switch source {
        case .off: show(nil)
        case .coverArt: show(coverURL)
        case .image: show(imagePath.flatMap { $0.isEmpty ? nil : URL(filePath: $0) })
        case .pinstill: shuffleNow()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard let interval = shuffle.interval else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.shuffleNow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Decodes at screen size off the main thread (Pinstill's upscaled images are large).
    private func show(_ url: URL?) {
        loadToken += 1
        let token = loadToken
        guard let url else {
            withAnimation(.easeInOut(duration: 1.2)) { image = nil; imageID = "" }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            var decoded: CGImage?
            if url.isFileURL {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    decoded = Self.downsample(source)
                }
            } else if let (data, _) = try? await URLSession.shared.data(from: url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) {
                decoded = Self.downsample(source)
            }
            await MainActor.run {
                guard let self, token == self.loadToken, let decoded else { return }
                withAnimation(.easeInOut(duration: 1.2)) {
                    self.image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                    self.imageID = url.path
                }
            }
        }
    }

    private static func downsample(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ] as CFDictionary)
    }
}

/// Size of the whole window's content, so each area can show its own slice of one
/// wallpaper and the sidebar, content and player bar line up as one picture.
struct WallpaperCanvasKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    var wallpaperCanvas: CGSize {
        get { self[WallpaperCanvasKey.self] }
        set { self[WallpaperCanvasKey.self] = newValue }
    }
}

/// The wallpaper layer: blurred and dimmed per settings, crossfading when it changes.
/// It draws the slice of a window-sized picture that sits under this view.
/// `sharp` shows it with no blur (Now Playing).
struct WallpaperBackground: View {
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(\.wallpaperCanvas) private var canvas
    var sharp = false

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let size = canvas == .zero ? proxy.size : canvas
            if let image = wallpaper.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: sharp && wallpaper.source != .coverArt ? 0 : wallpaper.blur, opaque: true)
                    .saturation(wallpaper.blur > 40 ? 1.3 : 1)
                    .overlay(Color.black.opacity(sharp ? 0.15 : wallpaper.dim))
                    .offset(x: canvas == .zero ? 0 : -frame.minX, y: canvas == .zero ? 0 : -frame.minY)
                    .id(wallpaper.imageID)
                    .transition(.opacity)
            }
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct SettingsView: View {
    @Environment(WallpaperStore.self) private var wallpaper

    var body: some View {
        @Bindable var wallpaper = wallpaper
        Form {
            Section("Wallpaper") {
                Picker("Show", selection: $wallpaper.source) {
                    ForEach(WallpaperStore.Source.allCases) { Text($0.label).tag($0) }
                }
                if wallpaper.source == .pinstill {
                    if wallpaper.boards.isEmpty {
                        Text("Pinstill isn't set up yet. Link a Pinterest board in Pinstill first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Board", selection: Binding(
                            get: { wallpaper.selectedBoard?.id ?? "" },
                            set: { wallpaper.boardID = $0 }
                        )) {
                            ForEach(wallpaper.boards) { Text($0.name).tag($0.id) }
                        }
                        Picker("Shuffle", selection: $wallpaper.shuffle) {
                            ForEach(WallpaperStore.Shuffle.allCases) { Text($0.label).tag($0) }
                        }
                        Button("Shuffle Now") { wallpaper.shuffleNow() }
                    }
                }
                if wallpaper.source == .image {
                    LabeledContent("Image") {
                        HStack {
                            Text(wallpaper.imagePath.map { URL(filePath: $0).lastPathComponent } ?? "None")
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseImage() }
                        }
                    }
                }
                if wallpaper.source != .off && wallpaper.source != .coverArt {
                    LabeledContent("Picture") {
                        Slider(value: $wallpaper.visibility, in: 0...1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("Soft").font(.caption)
                        } maximumValueLabel: {
                            Text("Clear").font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { wallpaper.loadBoards() }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            wallpaper.imagePath = url.path
        }
    }
}
