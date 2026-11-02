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
        case matchSong, everySong, every5Minutes, every30Minutes, manual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .matchSong: "Every song, matching its cover"
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
    /// Average brightness of the image on screen, 0 (black) to 1 (white).
    private(set) var brightness = 0.0

    /// The black wash over the picture. In dark mode it's raised as far as needed
    /// to keep a light picture (a pale cover, a snowy board) from going grey-white
    /// behind white text: the result stays at or under `ceiling` brightness.
    func wash(sharp: Bool, dark: Bool) -> Double {
        let base = sharp ? 0.15 : dim
        guard dark, brightness > 0 else { return base }
        let ceiling = sharp ? 0.42 : 0.3
        return min(0.85, max(base, 1 - ceiling / brightness))
    }

    /// The wallpaper's main colour, for the sidebar, player bar and queue, so the
    /// panels and the picture share one colour instead of competing.
    private(set) var tint: Color?

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
        case .pinstill where shuffle == .matchSong: matchCover()
        default: break
        }
    }

    /// Shows the board picture whose colours come closest to the playing song's
    /// cover, picking among the three closest so the same one doesn't always win.
    /// Each picture's colour is measured once and kept on disk per board.
    private func matchCover() {
        guard source == .pinstill, let board = selectedBoard, let cover = coverURL else { return shuffleNow() }
        let current = imageID
        Task.detached(priority: .utility) { [weak self] in
            guard let coverImage = await ImageDecodeCache.shared.image(cover, maxPixelSize: 64) else { return }
            let target = Self.signature(coverImage)
            let key = "board-colors-" + board.id
            var known = DiskCache.load([String: [Double]].self, key) ?? [:]
            let files = ((try? FileManager.default.contentsOfDirectory(at: board.folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["jpg", "jpeg", "png", "heic", "webp"].contains($0.pathExtension.lowercased()) }
            var measured = false
            for file in files where known[file.lastPathComponent] == nil {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 64,
                      ] as CFDictionary) else { continue }
                known[file.lastPathComponent] = Self.signature(thumb)
                measured = true
            }
            if measured { DiskCache.save(known, key) }
            func distance(_ c: [Double]) -> Double {
                var sum = 0.0
                for i in 0..<3 { sum += (c[i] - target[i]) * (c[i] - target[i]) }
                return sum
            }
            var ranked: [(file: URL, distance: Double)] = []
            for file in files where file.path != current {
                if let c = known[file.lastPathComponent] { ranked.append((file, distance(c))) }
            }
            ranked.sort { $0.distance < $1.distance }
            guard let pick = ranked.prefix(3).randomElement()?.file else { return }
            await MainActor.run { [weak self] in
                guard let self, self.coverURL == cover, self.shuffle == .matchSong else { return }
                self.show(pick)
            }
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
        case .pinstill: shuffle == .matchSong ? matchCover() : shuffleNow()
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
            withAnimation(.easeInOut(duration: 1.2)) { image = nil; imageID = ""; brightness = 0; tint = nil }
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
            let light = decoded.map(Self.averageBrightness) ?? 0
            let color = decoded.map(Self.mainColor)
            await MainActor.run {
                guard let self, token == self.loadToken, let decoded else { return }
                withAnimation(.easeInOut(duration: 1.2)) {
                    self.image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                    self.imageID = url.path
                    self.brightness = light
                    self.tint = color
                }
            }
        }
    }

    /// Average colour, weighted toward saturated pixels so a grey background
    /// doesn't win over the coloured subject. RGB, 0 to 1.
    static func signature(_ image: CGImage) -> [Double] {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [0.5, 0.5, 0.5] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            let weight = (maxC - minC) + 0.05
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        return [r / total, g / total, b / total]
    }

    /// The picture's main colour, toned down to sit behind white text.
    static func mainColor(_ image: CGImage) -> Color {
        let rgb = signature(image)
        let ns = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        return Color(hue: h, saturation: min(0.22, s * 0.8), brightness: 0.17)
    }

    /// Draws the image into one pixel and reads its luma.
    private static func averageBrightness(_ image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
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

/// Background for the sidebar, player bar and queue over a wallpaper: their slice of
/// the blurred wallpaper under a wash of its own main colour.
struct PanelBackground: View {
    @Environment(WallpaperStore.self) private var wallpaper

    var body: some View {
        ZStack {
            WallpaperBackground()
            (wallpaper.tint ?? .black).opacity(0.7)
        }
        .allowsHitTesting(false)
    }
}

/// The wallpaper layer: blurred and dimmed per settings, crossfading when it changes.
/// It draws the slice of a window-sized picture that sits under this view.
/// `sharp` shows it with no blur (Now Playing).
struct WallpaperBackground: View {
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(\.wallpaperCanvas) private var canvas
    @Environment(\.colorScheme) private var colorScheme
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
                    .overlay(Color.black.opacity(wallpaper.wash(sharp: sharp, dark: colorScheme == .dark)))
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

struct WallpaperSettings: View {
    @Environment(WallpaperStore.self) private var wallpaper

    var body: some View {
        @Bindable var wallpaper = wallpaper
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
