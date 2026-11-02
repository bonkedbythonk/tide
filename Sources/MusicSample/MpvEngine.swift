import AppKit
import Libmpv
import QuartzCore

/// The layer mpv draws video into (MPVKit's moltenvk context takes it as `wid`).
/// MoltenVK briefly sets the drawable to 1x1 during a resize; refusing that keeps
/// the picture from flickering or sticking at 1x1 (MPVKit's own workaround).
final class MpvMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue } }
    }
}

/// Layer-hosting view for the video. It only keeps the drawable size in step
/// with its bounds; mpv does the drawing.
final class MpvMetalView: NSView {
    let metalLayer = MpvMetalLayer()
    var onDrawableSizeChanged: ((CGSize) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = 2
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard target.width > 1, target.height > 1, metalLayer.drawableSize != target else { return }
        metalLayer.drawableSize = target
        onDrawableSizeChanged?(target)
    }
}

/// One libmpv instance for the whole app: audio always, video into `videoView`
/// when the current track plays as a music video.
final class MpvEngine {
    let videoView = MpvMetalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))

    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onVideoAspect: ((Double) -> Void)?
    var onPause: ((Bool) -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onEnded: (() -> Void)?
    var onFileLoaded: (() -> Void)?
    var onError: ((String) -> Void)?

    private var mpv: OpaquePointer?
    private var nudgeRestore: DispatchWorkItem?

    init() {
        guard let handle = mpv_create() else { return }
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(videoView.metalLayer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        let options: [(String, String)] = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("input-default-bindings", "no"), ("input-cursor", "no"),
            ("input-vo-keyboard", "no"), ("input-media-keys", "no"),
            ("osc", "no"), ("osd-level", "0"),
            ("idle", "yes"), ("keep-open", "no"), ("ytdl", "no"),
            ("cache", "yes"), ("demuxer-max-bytes", "64M"), ("demuxer-readahead-secs", "20"),
            ("audio-display", "no"), ("terminal", "yes"), ("msg-level", "all=warn"),
        ]
        for (k, v) in options { mpv_set_option_string(handle, k, v) }
        // From anicat: on macOS 27, mpv 0.41's CoreAudio output fails to start with
        // planar audio and then crashes on the next device change. Interleaved float
        // stereo makes it start.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            mpv_set_option_string(handle, "audio-format", "float")
            mpv_set_option_string(handle, "audio-channels", "stereo")
        }
        guard mpv_initialize(handle) >= 0 else {
            mpv_destroy(handle)
            return
        }
        mpv = handle
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 5, "video-params/aspect", MPV_FORMAT_DOUBLE)

        videoView.onDrawableSizeChanged = { [weak self] _ in self?.nudgeVideoSize() }

        let thread = Thread { [weak self] in self?.eventLoop(handle) }
        thread.name = "mpv events"
        thread.start()
    }

    var isAvailable: Bool { mpv != nil }

    /// Plays one track. `video` nil means audio only.
    /// `gainDb` lowers loud tracks to YouTube Music's level (0 = as mastered).
    func load(audio: URL, video: URL?, start: Double, paused: Bool, gainDb: Double) {
        set("vid", video == nil ? "no" : "auto")
        set("pause", paused ? "yes" : "no")
        set("volume-gain", String(format: "%.2f", gainDb))
        // YouTube serves video and audio as separate streams. Registering the audio
        // before loading makes mpv open both and start them together; adding it
        // after the video had loaded left the first seconds silent.
        command(["change-list", "audio-files", "clr", ""])
        if let video, video != audio {
            command(["change-list", "audio-files", "append", audio.absoluteString])
        }
        command(["loadfile", (video ?? audio).absoluteString, "replace", "-1", "start=\(start)"])
    }

    func stop() { command(["stop"]) }

    /// Puts a video picture on the track that's already playing; the audio carries on.
    func addVideo(_ url: URL) {
        set("vid", "auto")
        command(["video-add", url.absoluteString, "select"])
    }

    func hideVideo() { set("vid", "no") }
    func seek(_ seconds: Double) { command(["seek", String(seconds), "absolute"]) }

    func set(_ property: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, property, value)
    }

    /// False when mpv refuses, e.g. `ao-volume` while no audio output exists yet.
    func trySet(_ property: String, _ value: String) -> Bool {
        guard let mpv else { return false }
        return mpv_set_property_string(mpv, property, value) >= 0
    }

    func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        cargs.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                _ = mpv_command(mpv, $0)
            }
        }
    }

    /// mpv's moltenvk context only re-reads the layer size when the video
    /// reconfigures, so after a resize nudge the aspect override to force one
    /// (anicat's fix, simplified).
    private func nudgeVideoSize() {
        guard let mpv else { return }
        nudgeRestore?.cancel()
        mpv_set_property_string(mpv, "video-aspect-override", "1.7787")
        let paused = (getString("pause") == "yes")
        let restore = DispatchWorkItem { [weak self] in self?.set("video-aspect-override", "-2") }
        nudgeRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + (paused ? 2 : 0.3), execute: restore)
    }

    private func getString(_ property: String) -> String? {
        guard let mpv, let c = mpv_get_property_string(mpv, property) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    private func eventLoop(_ handle: OpaquePointer) {
        while true {
            guard let event = mpv_wait_event(handle, -1)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let p = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let data = p.data else { continue }
                let name = String(cString: p.name)
                if p.format == MPV_FORMAT_DOUBLE {
                    let value = data.assumingMemoryBound(to: Double.self).pointee
                    DispatchQueue.main.async { [weak self] in
                        switch name {
                        case "time-pos": self?.onTime?(value)
                        case "duration": self?.onDuration?(value)
                        default: self?.onVideoAspect?(value)
                        }
                    }
                } else if p.format == MPV_FORMAT_FLAG {
                    let value = data.assumingMemoryBound(to: Int32.self).pointee != 0
                    DispatchQueue.main.async { [weak self] in
                        if name == "pause" { self?.onPause?(value) } else { self?.onBuffering?(value) }
                    }
                }
            case MPV_EVENT_FILE_LOADED:
                DispatchQueue.main.async { [weak self] in self?.onFileLoaded?() }
            case MPV_EVENT_END_FILE:
                guard let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { continue }
                if end.reason == MPV_END_FILE_REASON_EOF {
                    DispatchQueue.main.async { [weak self] in self?.onEnded?() }
                } else if end.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(end.error))
                    DispatchQueue.main.async { [weak self] in self?.onError?(message) }
                }
            default:
                continue
            }
        }
    }
}
