import AppKit
import ImageIO
import ObjectiveC
import SwiftUI

// Scroll-performance fixes ported from anicat (see its DesignSystem folder for
// the measurements behind each one).

/// Puts SwiftUI's scroll views on AppKit's responsive scrolling path, so pages
/// scroll at the display's 120 Hz instead of every second refresh. Horizontal
/// shelves stay on the old path: on the responsive one a vertical swipe that
/// starts while a shelf still has momentum is routed to the shelf and lost.
enum ResponsiveScrollingPatch {
    static let applyOnce: Void = {
        let names = ["SwiftUI.HostingScrollView", "_TtC7SwiftUI17HostingScrollView"]
        guard let cls = names.lazy.compactMap({ NSClassFromString($0) }).first,
              cls is NSScrollView.Type,
              let meta = object_getClass(cls) else { return }
        let selector = NSSelectorFromString("isCompatibleWithResponsiveScrolling")
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        if let method = class_getClassMethod(cls, selector) {
            method_setImplementation(method, imp_implementationWithBlock(yes))
        } else {
            class_addMethod(meta, selector, imp_implementationWithBlock(yes), "B@:")
        }

        guard let shelfClass = objc_allocateClassPair(cls, "MusicShelfScrollView", 0),
              let shelfMeta = object_getClass(shelfClass) else { return }
        let no: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_addMethod(shelfMeta, selector, imp_implementationWithBlock(no), "B@:")
        objc_registerClassPair(shelfClass)

        let moveSelector = NSSelectorFromString("viewWillMoveToWindow:")
        typealias MoveFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        guard let moveMethod = class_getInstanceMethod(cls, moveSelector) else { return }
        let originalMove = unsafeBitCast(method_getImplementation(moveMethod), to: MoveFn.self)
        let moveBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { object, window in
            // A horizontal strip answers yes for the horizontal axis; the vertical page doesn't.
            if window != nil, object_getClass(object) == cls, let scrollView = object as? NSScrollView,
               MainActor.assumeIsolated({ scrollView.wantsForwardedScrollEvents(for: .horizontal) }) {
                object_setClass(object, shelfClass)
            }
            originalMove(object, moveSelector, window)
        }
        method_setImplementation(moveMethod, imp_implementationWithBlock(moveBlock))
    }()
}

/// Scroll-wheel events from a listen-only CGEvent tap. With responsive scrolling
/// on, trackpad scrolls are handled off the main thread and a local NSEvent
/// monitor misses almost all of them; the tap sees every one.
@MainActor
final class ScrollEventTap {
    static let shared = ScrollEventTap()

    private var tap: CFMachPort?
    private var handlers: [(NSEvent) -> Void] = []

    func subscribe(_ handler: @escaping (NSEvent) -> Void) {
        handlers.append(handler)
        if tap == nil { install() }
    }

    private func install() {
        let callback: CGEventTapCallBack = { _, type, cgEvent, _ in
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = ScrollEventTap.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    ScrollEventTap.shared.deliver(cgEvent)
                }
            }
            return Unmanaged.passUnretained(cgEvent)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: callback, userInfo: nil
        ) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }

    private func deliver(_ cgEvent: CGEvent) {
        guard NSApp.isActive, let event = NSEvent(cgEvent: cgEvent) else { return }
        handlers.forEach { $0(event) }
    }
}

/// True while a scroll gesture runs (and 120 ms after). Hover views leave
/// hit-testing meanwhile: SwiftUI otherwise re-tests every hover responder on
/// each frame that moves content under the pointer.
@MainActor @Observable
final class ScrollActivity {
    static let shared = ScrollActivity()
    var isScrolling = false
    @ObservationIgnored private var settle: DispatchWorkItem?

    private init() {
        ScrollEventTap.shared.subscribe { [weak self] _ in
            guard let self else { return }
            if !isScrolling { isScrolling = true }
            settle?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.isScrolling = false }
            settle = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }
    }
}

private struct StableHoverModifier: ViewModifier {
    let perform: (Bool) -> Void
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard !ScrollActivity.shared.isScrolling, !isHovering else { return }
                    isHovering = true
                    perform(true)
                case .ended:
                    guard isHovering else { return }
                    isHovering = false
                    perform(false)
                }
            }
            // Outermost, so the hover responder itself leaves the hit-test walk.
            .allowsHitTesting(!ScrollActivity.shared.isScrolling)
    }
}

extension View {
    /// Like `.onHover`, but ignores content scrolling under a still pointer and
    /// costs nothing while a scroll runs.
    func stableHover(perform: @escaping (Bool) -> Void) -> some View {
        modifier(StableHoverModifier(perform: perform))
    }
}

/// Fetches and decodes cover art at its on-screen pixel size, off the main
/// thread, and keeps the decoded image. Plain AsyncImage decodes the full
/// image again every time a row scrolls back into view.
final class ImageDecodeCache: @unchecked Sendable {
    static let shared = ImageDecodeCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MusicApp/images", isDirectory: true)
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        config.urlCache = URLCache(memoryCapacity: 50 << 20, diskCapacity: 500 << 20, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private init() {
        cache.countLimit = 800
        cache.totalCostLimit = 300 << 20
    }

    private func key(_ url: URL, _ px: CGFloat) -> String { url.absoluteString + "#\(Int(px))" }

    func cached(_ url: URL, maxPixelSize px: CGFloat) -> CGImage? {
        lock.withLock { cache.object(forKey: key(url, px) as NSString)?.image }
    }

    func image(_ url: URL, maxPixelSize px: CGFloat) async -> CGImage? {
        let k = key(url, px)
        if let hit = cached(url, maxPixelSize: px) { return hit }
        let task: Task<CGImage?, Never> = lock.withLock {
            if let existing = inFlight[k] { return existing }
            let t = Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let (data, _) = try? await Self.session.data(from: url),
                      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: px,
                ] as CFDictionary)
            }
            inFlight[k] = t
            return t
        }
        let result = await task.value
        lock.withLock {
            inFlight[k] = nil
            if let result { cache.setObject(Box(result), forKey: k as NSString, cost: result.bytesPerRow * result.height) }
        }
        return result
    }
}

struct CachedImage: View {
    let url: URL
    let maxPixelSize: CGFloat
    @State private var image: CGImage?

    init(url: URL, maxPixelSize: CGFloat) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        _image = State(initialValue: ImageDecodeCache.shared.cached(url, maxPixelSize: maxPixelSize))
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            // A reused row can hand this view a different song's URL: show that one,
            // never the previous picture.
            image = ImageDecodeCache.shared.cached(url, maxPixelSize: maxPixelSize)
            if image == nil { image = await ImageDecodeCache.shared.image(url, maxPixelSize: maxPixelSize) }
        }
    }
}
