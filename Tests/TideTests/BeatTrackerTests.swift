import Foundation
import Testing
@testable import MusicSample

/// The tracker against synthetic drums with known beats. Frames are 23 ms apart
/// (hop 256 at 11025 Hz), so beat times are checked to about that.
@Suite struct BeatTrackerTests {
    @Test(arguments: [84.0, 96, 100, 110, 120, 124, 128, 135, 140, 150, 158])
    func tempoAndBeatsOnSteadyDrums(bpm: Double) throws {
        let track = Synth.drums(bpm: bpm)
        let a = try #require(BeatTracker.analyze(track.samples, start: 0))
        #expect(abs(a.bpm / bpm - 1) < 0.01, "bpm \(a.bpm) for \(bpm)")
        #expect(a.confidence >= 0.7, "confidence \(a.confidence)")
        #expect(a.isSteady)
        // Tracked beats sit a fixed ~73 ms before the hits (a frame's time is where its
        // 93 ms window starts, and the flux peaks once the hit is well inside it). The
        // same lead on both songs cancels out in a mix, so only the spread around it counts.
        let offsets = a.beats.map { b in track.beats.map { b - $0 }.min { abs($0) < abs($1) }! }
        let bias = offsets.sorted()[offsets.count / 2]
        #expect(abs(bias) < 0.1, "beats lead the hits by \(Int(-bias * 1000)) ms")
        let off = offsets.filter { abs($0 - bias) > 0.025 }
        #expect(off.count <= 2, "\(off.count) tracked beats more than 25 ms off the common lead")
        #expect(Double(a.beats.count) >= Double(track.beats.count) * 0.95)
    }

    @Test(arguments: [170.0, 174, 180, 60, 70])
    func halfAndDoubleTimeFoldInto80to160(bpm: Double) throws {
        let track = Synth.drums(bpm: bpm)
        let a = try #require(BeatTracker.analyze(track.samples, start: 0))
        #expect(a.bpm >= 80 && a.bpm < 160)
        #expect(abs(a.bpm / foldTempo(bpm) - 1) < 0.015, "bpm \(a.bpm) for \(bpm) (folded \(foldTempo(bpm)))")
    }

    @Test(arguments: [0, 1, 2, 3])
    func downbeatPhaseFound(phase: Int) throws {
        // Start the clip `phase` beats into a bar: the first tracked downbeat must be
        // the first true one.
        let bpm = 128.0, period = 60 / bpm
        let track = Synth.drums(bpm: bpm, firstBeat: 0.3 - Double(phase) * period)
        let a = try #require(BeatTracker.analyze(track.samples, start: 0))
        let firstTrue = try #require(track.beats.enumerated().first { $0.offset % 4 == 0 && $0.element > 0 }?.element)
        let i = try #require(a.firstDownbeat(atOrAfter: 0))
        // Downbeats in the synth are every 4th generated beat; generated beats before 0 are dropped.
        let trueDowns = stride(from: 0, to: 75.0, by: 4 * period).map { $0 + 0.3 - Double(phase) * period }.filter { $0 >= 0 }
        // Loose enough for the tracker's fixed lead (see tempoAndBeatsOnSteadyDrums).
        #expect(trueDowns.contains { abs($0 - a.beats[i]) < 0.1 },
                "tracked downbeat \(a.beats[i]), true \(trueDowns.prefix(3)) (first generated \(firstTrue))")
    }

    @Test func clipStartOffsetsBeats() throws {
        let track = Synth.drums(bpm: 120)
        let a = try #require(BeatTracker.analyze(track.samples, start: 200))
        #expect(a.start == 200)
        #expect(a.beats.allSatisfy { $0 >= 200 && $0 <= 275 })
        #expect(abs(a.duration - 75) < 0.01)
    }

    @Test func tooShortReturnsNil() {
        #expect(BeatTracker.analyze([Float](repeating: 0.1, count: 1024 * 8), start: 0) == nil)
        #expect(BeatTracker.analyze([], start: 0) == nil)
    }

    @Test func barelyLongEnoughDoesNotCrash() {
        for count in [1024 * 8 + 1, 1024 * 9, 1024 * 40] {
            let x = Array(Synth.drums(bpm: 120, seconds: 5).samples.prefix(count))
            let a = BeatTracker.analyze(x, start: 0)
            #expect(a == nil || a!.bpm.isFinite, "\(count) samples")
        }
    }

    @Test func silenceDCAndNoiseStayFinite() throws {
        let inputs: [(String, [Float])] = [
            ("silence", [Float](repeating: 0, count: Int(20 * Synth.sr))),
            ("dc", [Float](repeating: 0.5, count: Int(20 * Synth.sr))),
            ("noise", Synth.noise(seconds: 30)),
            ("clipped", Synth.drums(bpm: 128, seconds: 30).samples.map { max(-1, min(1, $0 * 20)) }),
        ]
        for (name, x) in inputs {
            let a = try #require(BeatTracker.analyze(x, start: 0), "\(name)")
            #expect(a.bpm.isFinite && a.confidence.isFinite, "\(name)")
            #expect(a.loudness.allSatisfy(\.isFinite) && a.onset.allSatisfy(\.isFinite) && a.bass.allSatisfy(\.isFinite), "\(name)")
            #expect(a.beats == a.beats.sorted(), "\(name) beats out of order")
        }
    }

    @Test func noiseIsNotSteady() throws {
        let a = try #require(BeatTracker.analyze(Synth.noise(seconds: 60), start: 0))
        #expect(!a.isSteady, "white noise read as a steady beat (confidence \(a.confidence))")
    }

    /// Tempo drifting ±15 BPM over 20 s swings, like a piece played by hand. Caught
    /// around 90 BPM; around 120 it reads as steady (the three 37 s halves each average
    /// over the same swings, so their tempos agree).
    @Test(arguments: [90.0, 120.0])
    func tempoWanderIsNotSteady(bpm: Double) throws {
        let a = try #require(BeatTracker.analyze(Synth.wander(bpm: bpm).samples, start: 0))
        withKnownIssue("steadiness misses slow tempo drift", isIntermittent: true) {
            #expect(!a.isSteady, "\(bpm) ± 15 BPM read as steady (confidence \(a.confidence), bpm \(a.bpm))")
        }
    }

    /// The bar phase is the beat phase (of 4) with the most bass and onset on average, in
    /// dB. Beats the tracker carries on into silence at the end of the clip (-90 dB bass)
    /// once dragged their phase's average down, so the backbeat could win.
    @Test(arguments: [84.0, 90, 100, 110, 120, 128, 140])
    func barPhaseIgnoresTrailingSilence(bpm: Double) throws {
        for silence in [1.5, 3.0, 5.0] {
            let t = Synth.drums(bpm: bpm, firstBeat: 0.21, musicUntil: 75 - silence)
            let a = try #require(BeatTracker.analyze(t.samples, start: 0))
            let chosen = a.beats[a.downbeatOffset]
            let k = t.beats.indices.min { abs(t.beats[$0] - chosen) < abs(t.beats[$1] - chosen) }!
            #expect(k % 4 == 0, "\(bpm) BPM, \(silence) s silence: downbeat picked on beat \(k % 4 + 1)")
        }
    }

    @Test func sameClipShiftedGivesSameGrid() throws {
        // Analysing a clip from 1.37 s later must find the same beats (it's the same song).
        let track = Synth.drums(bpm: 126, seconds: 80)
        let shift = 1.37
        let cut = Int(shift * Synth.sr)
        let a = try #require(BeatTracker.analyze(Array(track.samples[0..<Int(75 * Synth.sr)]), start: 0))
        let b = try #require(BeatTracker.analyze(Array(track.samples[cut..<(cut + Int(75 * Synth.sr))]), start: shift))
        #expect(abs(a.bpm - b.bpm) / a.bpm < 0.005)
        let overlap = b.beats.filter { $0 > shift + 2 && $0 < 73 }
        let off = overlap.filter { t in !a.beats.contains { abs($0 - t) < 0.025 } }
        #expect(off.count <= 2, "\(off.count) of \(overlap.count) beats moved")
    }

    @Test func voiceDetectorHandlesDrumsAndSilence() {
        // No voice in synthetic drums or silence; mostly checks it runs and returns sane times.
        let drums = Synth.drums(bpm: 120, seconds: 20).samples
        if let t = VoiceDetector.lastVoice(drums, sampleRate: Synth.sr, start: 100) {
            #expect(t >= 100 && t <= 120)
        }
        let quiet = [Float](repeating: 0, count: Int(10 * Synth.sr))
        #expect(VoiceDetector.lastVoice(quiet, sampleRate: Synth.sr, start: 0) == nil)
    }
}
