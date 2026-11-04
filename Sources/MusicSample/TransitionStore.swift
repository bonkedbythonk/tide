import Foundation
import os

/// Fetches and caches the analyses smart transitions plan from: the last 75 s of
/// the playing song and the first 75 s of the next, each listened to once and kept
/// on disk by video id.
enum TransitionStore {
    static let log = Logger(subsystem: "local.music-sample", category: "transitions")
    private static let clip: TimeInterval = 75

    /// - Parameter audioURL: the song's audio link and when it starts answering.
    static func plan(from a: String, length: TimeInterval, to b: String, fallbackFade: TimeInterval,
                     audioURL: @escaping (String) async -> (URL, Date)?) async -> TransitionPlan? {
        async let tail = analysis(a, tail: true, length: length, audioURL: audioURL)
        async let head = analysis(b, tail: false, length: 0, audioURL: audioURL)
        guard let tail = await tail, let head = await head else { return nil }
        return TransitionPlanner.plan(tail: tail, length: length, head: head, fallbackFade: fallbackFade)
    }

    private static func analysis(_ id: String, tail: Bool, length: TimeInterval,
                                 audioURL: (String) async -> (URL, Date)?) async -> BeatAnalysis? {
        let name = "beats75-\(id)-\(tail ? "tail" : "head")"
        if let cached = DiskCache.load(BeatAnalysis.self, name) { return cached }
        guard AudioClip.ffmpeg != nil, let (url, availableAt) = await audioURL(id) else { return nil }
        let wait = availableAt.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait + 0.2)) }
        let start = tail ? max(0, length - clip) : 0
        guard let samples = await AudioClip.decode(url, from: start, seconds: clip),
              let result = BeatTracker.analyze(samples, start: start) else { return nil }
        DiskCache.save(result, name)
        return result
    }
}
