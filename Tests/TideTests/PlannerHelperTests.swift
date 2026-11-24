import Foundation
import Testing
@testable import MusicSample

@Suite struct TempoMathTests {
    @Test func foldTempoValues() {
        #expect(foldTempo(0) == 0)
        #expect(foldTempo(-10) == 0)
        #expect(foldTempo(40) == 80)
        #expect(foldTempo(80) == 80)
        #expect(foldTempo(159.9) == 159.9)
        #expect(foldTempo(160) == 80)
        #expect(foldTempo(174) == 87)
        #expect(foldTempo(320) == 80)
        #expect(foldTempo(65) == 130)
    }

    @Test func tempoMatchValues() throws {
        let m = try #require(tempoMatch(bpmA: 128, bpmB: 126))
        #expect(abs(m.speed - 128.0 / 126) < 1e-9)
        let half = try #require(tempoMatch(bpmA: 128, bpmB: 64))
        #expect(abs(half.speed - 1) < 1e-9)
        let double = try #require(tempoMatch(bpmA: 87, bpmB: 174))
        #expect(abs(double.speed - 1) < 1e-9)
        #expect(tempoMatch(bpmA: 128, bpmB: 140) == nil)
        #expect(tempoMatch(bpmA: 20, bpmB: 40) == nil)
        #expect(tempoMatch(bpmA: 128, bpmB: 122, maxDiff: 0.05) != nil)
    }
}

@Suite struct BeatGridTests {
    @Test func fitPerfectLine() throws {
        let beats = (0..<16).map { 10.0 + Double($0) * 0.5 }
        let f = try #require(TransitionPlanner.fit(beats))
        #expect(abs(f.period - 0.5) < 1e-12)
        #expect(f.jitter < 1e-9)
        #expect(abs(f.first - 10) < 1e-9)
    }

    @Test func fitRejectsShortOrBackwards() {
        #expect(TransitionPlanner.fit([1, 2, 3, 4, 5, 6, 7]) == nil)
        #expect(TransitionPlanner.fit((0..<10).map { 10 - Double($0) }) == nil)
        #expect(TransitionPlanner.fit([Double](repeating: 3, count: 10)) == nil)
    }

    @Test func fitMeasuresJitter() throws {
        let beats = (0..<16).map { Double($0) * 0.5 + ($0 % 2 == 0 ? 0.02 : -0.02) }
        let f = try #require(TransitionPlanner.fit(beats))
        #expect(abs(f.jitter - 0.02) < 0.002)
    }

    @Test func refinePullsLineOntoHits() {
        let a = Make.analysis(bpm: 128, firstBeat: 0.513)
        let truth = a.beats[8], period = 60 / 128.0
        // Start 30 ms off and 0.3% slow.
        let r = TransitionPlanner.refine(a, first: truth + 0.03, period: period * 1.003, count: 32)
        #expect(abs(r.first - truth) < 0.012, "first \(r.first) vs \(truth)")
        #expect(abs(r.period / period - 1) < 0.002)
    }

    @Test func refineWithoutOnsetsLeavesLine() {
        var a = Make.analysis()
        a.onset = []
        let r = TransitionPlanner.refine(a, first: 3, period: 0.5, count: 16)
        #expect(r.first == 3 && r.period == 0.5)
    }

    @Test func onBeatAcceptsGridRejectsOffbeat() {
        let a = Make.analysis(bpm: 120)
        let period = 0.5
        #expect(TransitionPlanner.onBeat(a, first: a.beats[4], period: period, count: 32))
        #expect(!TransitionPlanner.onBeat(a, first: a.beats[4] + period / 2, period: period, count: 32))
        #expect(!TransitionPlanner.onBeat(a, first: a.beats[4] + period / 4, period: period, count: 32))
    }

    @Test func onHitsCountsBeatsOnOnsets() {
        let a = Make.analysis(bpm: 120)
        #expect(TransitionPlanner.onHits(a, Array(a.beats[0..<32])))
        #expect(!TransitionPlanner.onHits(a, a.beats[0..<32].map { $0 + 0.25 }))
    }

    /// Beats before the first or past the last onset frame, or an analysis with no
    /// onsets, once built an inverted range and trapped. Run in a child process so a
    /// regression fails this test instead of ending the suite.
    @Test func onHitsWithBeatsOutsideOnsetsDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let a = Make.analysis(duration: 20)
            precondition(!TransitionPlanner.onHits(a, [a.start + 25, a.start + 30]))
            precondition(!TransitionPlanner.onHits(a, [a.start - 5]))
            var empty = a
            empty.onset = []
            precondition(!TransitionPlanner.onHits(empty, [a.start + 1]))
        }
    }

    @Test func downbeatOffsetAndSnapping() {
        for d in 0..<4 {
            let a = Make.analysis(downbeat: d)
            #expect(a.downbeatOffset == d)
            #expect((a.snapDownbeat(atOrBefore: 21) - d) % 4 == 0)
            #expect(a.snapDownbeat(atOrBefore: 21) <= 21)
            #expect((a.snapDownbeat(atOrAfter: 21) - d) % 4 == 0)
            #expect(a.snapDownbeat(atOrAfter: 21) >= 21)
        }
        let a = Make.analysis(downbeat: 2)
        #expect(a.snapDownbeat(atOrBefore: 1) == 0)  // nothing at or before: clamps to 0
        #expect(a.snapDownbeat(atOrAfter: a.beats.count + 10) <= a.beats.count - 1)
        #expect(a.snapDownbeat(atOrBefore: -5) >= 0)
    }

    @Test func snappingWithFewBeats() {
        var a = Make.analysis()
        a.beats = Array(a.beats.prefix(3))
        #expect(a.downbeatOffset == 0)
        #expect(a.snapDownbeat(atOrAfter: 2) <= 2)
        a.beats = []
        #expect(a.snapDownbeat(atOrAfter: 5) == 0)
        #expect(a.firstDownbeat(atOrAfter: 0) == nil)
    }
}

@Suite struct SectionTests {
    @Test func loudnessEdges() throws {
        // Silence until 2 s, music to 68 s, then silence.
        let a = Make.analysis(start: 100, level: { t in (t - 100) < 2 || (t - 100) > 68 ? -90 : -12 })
        let first = try #require(TransitionPlanner.firstLoud(a))
        let last = try #require(TransitionPlanner.lastLoud(a))
        let body = try #require(TransitionPlanner.bodyEnd(a))
        #expect(abs(first - 102) < 0.05)
        #expect(abs(last - 168) < 0.05)
        #expect(abs(body - 168) < 0.6)
    }

    @Test func decayTailIsKeptButBodyEndsBeforeIt() throws {
        // Full until 60 s, then a 10 s fade from -12 to -50 dB.
        let a = Make.analysis(level: { t in t < 60 ? -12 : Float(-12 - 3.8 * (t - 60)) })
        let body = try #require(TransitionPlanner.bodyEnd(a))
        let last = try #require(TransitionPlanner.lastLoud(a))
        #expect(body > 62 && body < 64.5, "body \(body)")
        #expect(last > 69, "last \(last)")
    }

    @Test func emptyLoudnessHasNoEdges() {
        var a = Make.analysis()
        a.loudness = []
        a.bass = []
        #expect(TransitionPlanner.firstLoud(a) == nil)
        #expect(TransitionPlanner.lastLoud(a) == nil)
        #expect(TransitionPlanner.bodyEnd(a) == nil)
        #expect(TransitionPlanner.bassEntry(a, from: 0) == nil)
    }

    @Test func bassEntryFindsLateBass() throws {
        let a = Make.analysis(bassLevel: { $0 < 20 ? -60 : -6 })
        let t = try #require(TransitionPlanner.bassEntry(a, from: 0))
        #expect(abs(t - 20) < 0.5)
        #expect(TransitionPlanner.bassEntry(a, from: 30).map { abs($0 - 30) < 0.5 } == true)
    }

    @Test func bassCarries() {
        let full = Make.analysis(bassLevel: { _ in -6 })
        #expect(TransitionPlanner.bassCarries(full, from: 50, to: 70))
        let drops = Make.analysis(bassLevel: { $0 < 50 ? -6 : -40 })
        #expect(!TransitionPlanner.bassCarries(drops, from: 50, to: 70))
        // Too little before to judge: assume it carries.
        #expect(TransitionPlanner.bassCarries(drops, from: 0, to: 0.1))
    }

    @Test func thinsOut() {
        let bpm = 128.0, period = 60 / bpm
        let flat = Make.analysis(bpm: bpm)
        let last = flat.beats.count - 1
        #expect(!TransitionPlanner.thinsOut(flat, last: last))
        let outroFrom = flat.beats[last - 32]
        let thin = Make.analysis(bpm: bpm, level: { $0 < outroFrom ? -10 : -16 })
        #expect(TransitionPlanner.thinsOut(thin, last: last))
        #expect(!TransitionPlanner.thinsOut(thin, last: 20))
        _ = period
    }

    @Test func outroAndDropFound() throws {
        let flat = Make.analysis()
        let last = flat.beats.count - 1
        #expect(TransitionPlanner.outroStart(flat, last: last) == nil)
        #expect(TransitionPlanner.dropAt(flat, first: 0) == nil)

        let outroAt = flat.beats[last - 32]
        let outro = Make.analysis(level: { $0 < outroAt ? -8 : -16 }, bassLevel: { $0 < outroAt ? -4 : -14 })
        let k = try #require(TransitionPlanner.outroStart(outro, last: last))
        #expect(abs(k - (last - 32)) <= 8, "outro at beat \(k), true \(last - 32)")

        let dropAt = flat.beats[48]
        let drop = Make.analysis(level: { $0 < dropAt ? -16 : -8 }, bassLevel: { $0 < dropAt ? -20 : -4 })
        let d = try #require(TransitionPlanner.dropAt(drop, first: 0))
        #expect(abs(d - 48) <= 8, "drop at beat \(d), true 48")
    }
}
