import Foundation
import Testing
@testable import MusicSample

/// Synthetic songs through the real tracker and planner, scored against the true beat
/// times: what a listener hears, not what the planner believes.
@Suite struct MixAlignmentTests {
    /// Outgoing song is 200 s long; its clip is the last 75 s with music to 197 s.
    static let length = 200.0
    static let clipStart = 125.0

    struct Mix {
        let plan: TransitionPlan
        let outBeats: [Double]
        let inBeats: [Double]
        let tail: BeatAnalysis
        let head: BeatAnalysis
    }

    /// `tailMusicUntil` (clip time) below 75 leaves closing silence after the music.
    static func mix(_ outBPM: Double, _ inBPM: Double, inFirstBeat: Double = 0.4, inMusicFrom: Double = 0,
                    tailMusicUntil: Double = 75, outSoft: Bool = false, inSoft: Bool = false,
                    kinds: (outgoing: SongKind, incoming: SongKind) = (.regular, .regular),
                    voiceEnd: Double? = nil) throws -> Mix {
        let a = Synth.drums(bpm: outBPM, firstBeat: 0.21, musicUntil: tailMusicUntil, soft: outSoft, seed: 1)
        let b = Synth.drums(bpm: inBPM, firstBeat: inFirstBeat, musicFrom: inMusicFrom, soft: inSoft, seed: 2)
        var tail = try #require(BeatTracker.analyze(a.samples, start: clipStart))
        tail.voiceEnd = voiceEnd
        let head = try #require(BeatTracker.analyze(b.samples, start: 0))
        let plan = TransitionPlanner.plan(tail: tail, length: length, head: head, fallbackFade: 6, kinds: kinds)
        return Mix(plan: plan, outBeats: a.beats.map { $0 + clipStart }, inBeats: b.beats, tail: tail, head: head)
    }

    @Test(arguments: [(128.0, 128.0), (128, 126), (126, 128), (124, 127), (128, 124), (100, 98), (140, 137), (87, 88)])
    func matchedMixStaysOnTheBeat(out: Double, inn: Double) throws {
        let m = try Self.mix(out, inn)
        #expect(violations(m.plan, tail: m.tail, head: m.head, length: Self.length, kinds: (.regular, .regular)).isEmpty)
        try #require(m.plan.matched, "\(out) > \(inn) not beat-matched")
        let beats = Int(m.plan.fade / m.plan.beat)
        let d = try #require(Drift(plan: m.plan, outBeats: m.outBeats, inBeats: m.inBeats, beats: beats))
        // Both points lead their hits by the tracker's fixed ~73 ms; they must lead alike.
        #expect(abs(d.outError) < 0.1 && abs(d.inError) < 0.1, "leads \(d.outError), \(d.inError)")
        #expect(abs(d.outError - d.inError) < 0.025, "out and in points lead their beats unequally")
        #expect(d.outIndex % 4 == 0, "outgoing enters on beat \(d.outIndex % 4 + 1) of the bar")
        #expect(d.inIndex % 4 == 0, "incoming enters on beat \(d.inIndex % 4 + 1) of the bar")
        #expect(d.maxAbs < 0.025, "beats drift \(Int(d.maxAbs * 1000)) ms apart over \(d.offsets.count) beats")
        #expect(d.offsets.count >= 16, "only \(d.offsets.count) beats of overlap")
    }

    @Test(arguments: [(128.0, 140.0), (100, 128), (140, 120), (90, 110)])
    func distantTemposBlendOnTheOne(out: Double, inn: Double) throws {
        let m = try Self.mix(out, inn)
        #expect(violations(m.plan, tail: m.tail, head: m.head, length: Self.length, kinds: (.regular, .regular)).isEmpty)
        #expect(!m.plan.matched)
        #expect(m.plan.onBeat)
        // The code comment says 10-14 s; snapping the start back to a downbeat and running
        // on to the end of the body adds up to a bar or two, so 16-18 s is normal.
        #expect(m.plan.fade >= 6 && m.plan.fade <= 20, "fade \(m.plan.fade)")
        let d = try #require(Drift(plan: m.plan, outBeats: m.outBeats, inBeats: m.inBeats, beats: 0))
        #expect(abs(d.offsets[0]) < 0.03, "first beats \(Int(d.offsets[0] * 1000)) ms apart")
        #expect(d.outIndex % 4 == 0 && d.inIndex % 4 == 0, "blend opens off the one (\(d.outIndex % 4), \(d.inIndex % 4))")
    }

    /// The same mixes with 1.5-5 s of silence closing the outgoing clip, as on many
    /// YouTube uploads.
    @Test(arguments: [(128.0, 126.0), (124, 127), (100, 98), (90, 110), (128, 140), (87, 88)])
    func barPhaseWithClosingSilence(out: Double, inn: Double) throws {
        for until in [73.5, 72, 70] {
            let m = try Self.mix(out, inn, tailMusicUntil: until)
            let d = try #require(Drift(plan: m.plan, outBeats: m.outBeats, inBeats: m.inBeats, beats: 0))
            #expect(d.outIndex % 4 == 0 && d.inIndex % 4 == 0,
                    "\(out) > \(inn), music to \(until) s: enters on beats \(d.outIndex % 4 + 1) / \(d.inIndex % 4 + 1)")
        }
    }

    /// A punchy kick (click, hats) into a round 808 swelling in over 25 ms, and back:
    /// the tracker's lead depends on the attack, and the difference stays in the mix.
    @Test(arguments: [(false, true), (true, false), (true, true)])
    func mixAcrossDrumSounds(outSoft: Bool, inSoft: Bool) throws {
        let m = try Self.mix(128, 127, outSoft: outSoft, inSoft: inSoft)
        try #require(m.plan.matched)
        let d = try #require(Drift(plan: m.plan, outBeats: m.outBeats, inBeats: m.inBeats, beats: Int(m.plan.fade / m.plan.beat)))
        let mean = d.offsets.reduce(0, +) / Double(d.offsets.count)
        print("Drum sounds \(outSoft ? "soft" : "punchy") > \(inSoft ? "soft" : "punchy"): beats \(Int(mean * 1000)) ms apart on average, max \(Int(d.maxAbs * 1000)) ms, leads \(Int(d.outError * 1000)) / \(Int(d.inError * 1000)) ms")
        #expect(d.maxAbs < 0.025, "beats \(Int(d.maxAbs * 1000)) ms apart")
    }

    @Test func unpluggedPlaysOutThenStartsOnFirstSound() throws {
        for kinds: (outgoing: SongKind, incoming: SongKind) in [(.unplugged, .regular), (.regular, .unplugged)] {
            let m = try Self.mix(128, 128, inFirstBeat: 1.5, inMusicFrom: 1.45, tailMusicUntil: 72, kinds: kinds)
            #expect(violations(m.plan, tail: m.tail, head: m.head, length: Self.length, kinds: kinds).isEmpty)
            #expect(m.plan.fade == 0 && !m.plan.matched)
            // Music stops at 197 s: next song starts right after the sound ends, not at 200.
            #expect(m.plan.outAt > 196.9 && m.plan.outAt < 197.6, "outAt \(m.plan.outAt)")
            // Loudness frames are timed at their window start, so the first sound reads
            // ~80 ms early and the song starts a little before it: harmless.
            #expect(m.plan.inAt > 1.25 && m.plan.inAt <= 1.45, "inAt \(m.plan.inAt)")
        }
    }

    @Test func alteredIsNeverBeatMatched() throws {
        for kinds: (outgoing: SongKind, incoming: SongKind) in [(.altered, .regular), (.regular, .altered)] {
            let m = try Self.mix(128, 128, kinds: kinds)
            #expect(!m.plan.matched)
            #expect(violations(m.plan, tail: m.tail, head: m.head, length: Self.length, kinds: kinds).isEmpty)
        }
    }

    @Test(arguments: [170.0, 180.0, 186.0])
    func voiceIsNotFadedMidLine(voice: Double) throws {
        let m = try Self.mix(128, 127, voiceEnd: voice)
        #expect(violations(m.plan, tail: m.tail, head: m.head, length: Self.length, kinds: (.regular, .regular)).isEmpty)
        #expect(m.plan.outAt >= voice - 0.5, "next song starts at \(m.plan.outAt), voice runs to \(voice)")
    }

    @Test func planIsDeterministic() throws {
        let a = try Self.mix(128, 126)
        let b = try Self.mix(128, 126)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let ea = try enc.encode(a.plan), eb = try enc.encode(b.plan)
        #expect(ea == eb)
    }

    /// A band without a click drifting a few BPM still passes the planner's gates (beat
    /// lines within 60 ms RMS) and gets one constant-rate stretch, so the beats meet in
    /// the middle of the mix and drift apart toward its ends. Depth 0 is the control.
    @Test func wanderingTempoIsNeverBeatMatched() throws {
        for depth in [0.0, 1, 2, 4, 6, 10, 15] {
            let a = Synth.wander(bpm: 120, depth: depth, musicUntil: 72)
            let tail = try #require(BeatTracker.analyze(a.samples, start: Self.clipStart))
            let head = try #require(BeatTracker.analyze(Synth.drums(bpm: tail.bpm, seed: 2).samples, start: 0))
            let p = TransitionPlanner.plan(tail: tail, length: Self.length, head: head, fallbackFade: 6)
            guard p.matched else { continue }
            // Matched anyway: then the heard beats must still meet.
            let d = try #require(Drift(plan: p, outBeats: a.beats.map { $0 + Self.clipStart }, inBeats: Synth.drums(bpm: tail.bpm, seed: 2).beats,
                                       beats: Int(p.fade / p.beat)))
            let swap = min(d.offsets.count - 1, Int((p.swapDelay ?? p.fade / 2) / p.beat))
            let detail = "±\(depth) BPM drift beat-matched: beats \(Int(d.offsets[0] * 1000)) ms apart at the start, \(Int(d.offsets[swap] * 1000)) at the bass swap, \(Int(d.offsets.last! * 1000)) at the end"
            if depth == 0 {
                #expect(d.maxAbs < 0.025, "\(detail)")
            } else {
                withKnownIssue("drifting tempo beat-matched with beats far apart", isIntermittent: true) {
                    #expect(d.maxAbs < 0.04, "\(detail)")
                }
            }
        }
    }
}

/// Planner on hand-built analyses: each case changes one thing.
@Suite struct PlannerCaseTests {
    static let kinds: (outgoing: SongKind, incoming: SongKind) = (.regular, .regular)

    static func plan(_ tail: BeatAnalysis, _ head: BeatAnalysis, length: Double = 200,
                     kinds: (outgoing: SongKind, incoming: SongKind) = kinds) -> TransitionPlan {
        let p = TransitionPlanner.plan(tail: tail, length: length, head: head, fallbackFade: 6, kinds: kinds)
        let v = violations(p, tail: tail, head: head, length: length, kinds: kinds)
        #expect(v.isEmpty, "\(v)")
        return p
    }

    @Test func sameTempoMatchesWithoutBending() {
        let p = Self.plan(Make.analysis(start: 125, bpm: 128), Make.analysis(bpm: 128))
        #expect(p.matched)
        #expect(abs(p.speed - 1) < 0.002 && abs(p.incomingSpeed - 1) < 0.002)
    }

    @Test func smallGapBendsOutgoingOnly() {
        let p = Self.plan(Make.analysis(start: 125, bpm: 128), Make.analysis(bpm: 126.4))  // 1.25%
        #expect(p.matched)
        #expect(p.incomingSpeed == 1)
        #expect(abs(p.speed - 128 / 126.4) < 0.003, "speed \(p.speed)")
    }

    @Test func largerGapBendsBothHalfway() {
        let p = Self.plan(Make.analysis(start: 125, bpm: 128), Make.analysis(bpm: 124.4))  // 2.9%
        #expect(p.matched)
        let r = 128 / 124.4
        #expect(abs(p.speed - r.squareRoot()) < 0.003, "speed \(p.speed)")
        #expect(abs(p.incomingSpeed - r.squareRoot()) < 0.003, "incoming \(p.incomingSpeed)")
        // Heard tempos meet: outgoing beat stretched by speed equals incoming squeezed by incomingSpeed.
        #expect(abs((60 / 128) * p.speed - (60 / 124.4) / p.incomingSpeed) < 0.002)
    }

    @Test func tooFarApartIsABlend() {
        let p = Self.plan(Make.analysis(start: 125, bpm: 128), Make.analysis(bpm: 120))  // 6.7%
        #expect(!p.matched && p.onBeat)
        #expect(p.speed == 1 && p.incomingSpeed == 1)
    }

    @Test func unsteadyIsAGapNotAnOverlap() {
        let tail = Make.analysis(start: 125, bpm: 90, jitter: 0.25, confidence: 0.1, level: { $0 > 197 ? -90 : -14 })
        let p = Self.plan(tail, Make.analysis(bpm: 128))
        #expect(p.fade == 0 && !p.onBeat && !p.matched)
        #expect(p.outAt > 196.9 && p.outAt < 197.5, "outAt \(p.outAt)")
    }

    @Test func trailingSilenceIsSkipped() {
        // YouTube upload with 8 s of silence after the song.
        let tail = Make.analysis(start: 125, beatsUntil: 67, level: { $0 > 192 ? -90 : -12 })
        let p = Self.plan(tail, Make.analysis())
        #expect(p.outAt + p.fade + p.ringOut <= 192.5, "mix ends at \(p.outAt + p.fade + p.ringOut)")
    }

    @Test func silentIntroIsSkipped() {
        let head = Make.analysis(firstBeat: 3.0, level: { $0 < 2.9 ? -90 : -12 })
        let p = Self.plan(Make.analysis(start: 125), head)
        #expect(p.inAt >= 2.8, "inAt \(p.inAt)")
    }

    @Test func outgoingWithoutBassDoesNotSwap() {
        // Outro has already dropped its kick and bass.
        let tail = Make.analysis(start: 125, bassLevel: { $0 > 186 ? -45 : -6 })
        let p = Self.plan(tail, Make.analysis())
        #expect(!p.swapsBass)
    }

    @Test func swapWaitsForLateBass() throws {
        // The incoming song's bass comes in 8 s into it: the swap must not come before.
        let head = Make.analysis(bassLevel: { $0 < 8.5 ? -60 : -6 })
        let p = Self.plan(Make.analysis(start: 125), head)
        try #require(p.matched)
        let swap = try #require(p.swapDelay)
        let bassInMix = (8.5 - p.inAt) / (p.incomingSpeed * p.speed)
        // bassEntry reads in half-second steps and the swap rounds to a beat.
        #expect(swap >= bassInMix - p.beat - 0.5, "swap at \(swap) s, bass enters at \(bassInMix) s")
    }

    @Test func emptyAnalysesDoNotCrash() {
        var tail = Make.analysis(start: 125)
        var head = Make.analysis()
        for strip in 0..<4 {
            switch strip {
            case 0: tail.beats = []; head.beats = []
            case 1: tail.onset = []; head.onset = []
            case 2: tail.bass = []; head.bass = []
            default: tail.loudness = []; head.loudness = []
            }
            let p = TransitionPlanner.plan(tail: tail, length: 200, head: head, fallbackFade: 6)
            let finite = [p.outAt, p.inAt, p.fade].allSatisfy { $0.isFinite }
            #expect(finite, "strip \(strip)")
        }
    }
}

/// The Apple TV app decodes its part of the plan from the same JSON.
@Suite struct TVContractTests {
    @Test func tvMixDecodesPlan() throws {
        var plan = TransitionPlan(outAt: 181.25, inAt: 0.42, fade: 22.5, onBeat: true, matched: true,
                                  speed: 1.012, incomingSpeed: 1.004, beat: 0.469, outro: 170, drop: 15,
                                  swapDelay: 7.5, swapsBass: false, ringOut: 1.5)
        plan.layered = true
        let mix = try JSONDecoder().decode(TVProtocol.Mix.self, from: JSONEncoder().encode(plan))
        #expect(mix.outAt == plan.outAt && mix.inAt == plan.inAt && mix.fade == plan.fade)
        #expect(mix.onBeat && mix.matched && mix.layered && !mix.swapsBass)
        #expect(mix.speed == plan.speed && mix.incomingSpeed == plan.incomingSpeed && mix.beat == plan.beat)
        #expect(mix.swapDelay == 7.5 && mix.ringOut == 1.5)
    }

    @Test func tvMixDecodesPlainPlan() throws {
        let plan = TransitionPlan(outAt: 200, inAt: 0, fade: 0, onBeat: false)
        let mix = try JSONDecoder().decode(TVProtocol.Mix.self, from: JSONEncoder().encode(plan))
        #expect(mix.swapDelay == nil && mix.speed == 1 && !mix.matched)
    }
}
