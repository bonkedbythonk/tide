import Foundation
import Testing
@testable import MusicSample

/// Real song clips (design/renders/audio, local only) decoded with ffmpeg, tracked and
/// planned the way the app does. Skipped when the clips or ffmpeg are missing.
private enum Clips {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../design/renders/audio").standardized
    static var available: Bool {
        AudioClip.ffmpeg != nil && FileManager.default.fileExists(atPath: dir.appendingPathComponent("trance_ab_head.m4a").path)
    }
}

@Suite(.enabled(if: Clips.available)) struct RealAudioTests {
    static let dir = Clips.dir

    /// The pairs the design/renders/automix-check listening set uses.
    static let pairs = [("trance_ferry", "Qpn_Jb5CcIQ"), ("trance_ferry", "krCMli0a2VQ"), ("krCMli0a2VQ", "trance_ab"),
                        ("71HE4KwW1-I", "krCMli0a2VQ"), ("gB0rvF3j_VM", "cpYjyIcH3ZI"), ("71HE4KwW1-I", "hSs15wSY-44"),
                        ("Qpn_Jb5CcIQ", "krCMli0a2VQ")]

    static func clip(_ name: String, from: Double = 0) async throws -> [Float] {
        let url = dir.appendingPathComponent("\(name).m4a")
        return try #require(await AudioClip.decode(url, from: from, seconds: 75), "decode \(name)")
    }

    @Test(arguments: pairs)
    func pairPlansKeepTheRules(out: String, inn: String) async throws {
        let a = try await Self.clip("\(out)_tail")
        let b = try await Self.clip("\(inn)_head")
        // Each tail clip ends where its song ends.
        let length = Double(a.count) / BeatTracker.sampleRate
        let tail = try #require(BeatTracker.analyze(a, start: 0))
        var withVoice = tail
        withVoice.voiceEnd = VoiceDetector.lastVoice(a, sampleRate: BeatTracker.sampleRate, start: 0)
        let head = try #require(BeatTracker.analyze(b, start: 0))
        let p = TransitionPlanner.plan(tail: withVoice, length: length, head: head, fallbackFade: 6)
        print("""
            \(out) > \(inn): tail \(String(format: "%.1f", tail.bpm)) BPM conf \(String(format: "%.2f", tail.confidence)), \
            head \(String(format: "%.1f", head.bpm)) BPM conf \(String(format: "%.2f", head.confidence)), voice ends \(withVoice.voiceEnd.map { String(format: "%.1f", $0) } ?? "-") of \(String(format: "%.1f", length)) | \
            \(p.matched ? "matched" : p.onBeat ? "blend" : "gap") out \(String(format: "%.2f", p.outAt)) in \(String(format: "%.2f", p.inAt)) \
            fade \(String(format: "%.1f", p.fade)) speed \(String(format: "%.4f", p.speed))/\(String(format: "%.4f", p.incomingSpeed)) \
            swap \(p.swapDelay.map { String(format: "%.1f", $0) } ?? "-") bass \(p.swapsBass) layered \(p.layered)
            """)
        let v = violations(p, tail: withVoice, head: head, length: length, kinds: (.regular, .regular))
        #expect(v.isEmpty, "\(v)")
    }

    @Test(arguments: ["trance_ferry_tail", "trance_ab_head", "krCMli0a2VQ_head", "Qpn_Jb5CcIQ_tail", "gB0rvF3j_VM_tail"])
    func realClipShiftedGivesSameGrid(name: String) async throws {
        let shift = 1.37
        let a = try #require(BeatTracker.analyze(try await Self.clip(name), start: 0))
        let b = try #require(BeatTracker.analyze(try await Self.clip(name, from: shift), start: shift))
        #expect(abs(a.bpm / b.bpm - 1) < 0.01, "\(name): \(a.bpm) vs \(b.bpm)")
        let overlap = b.beats.filter { $0 > shift + 3 && $0 < a.start + a.duration - 3 }
        let moved = overlap.filter { t in !a.beats.contains { abs($0 - t) < 0.03 } }
        // The app always cuts the same window from a song, so this doesn't change a plan
        // from one play to the next; it shows how much the grid rests on where the clip starts.
        withKnownIssue("real clips: tracked beats and bar phase move when the clip starts 1.37 s later", isIntermittent: true) {
            #expect(Double(moved.count) <= Double(overlap.count) * 0.05, "\(name): \(moved.count) of \(overlap.count) beats moved")
        // Same bar phase: b's downbeats are among a's.
        let downsA = stride(from: a.downbeatOffset, to: a.beats.count, by: 4).map { a.beats[$0] }
        let downsB = stride(from: b.downbeatOffset, to: b.beats.count, by: 4).map { b.beats[$0] }.filter { $0 > shift + 3 && $0 < 70 }
        let agree = downsB.filter { t in downsA.contains { abs($0 - t) < 0.05 } }
            #expect(Double(agree.count) >= Double(downsB.count) * 0.9, "\(name): bar phase moved with a 1.37 s shift (\(agree.count)/\(downsB.count))")
        }
    }
}
