import Foundation
import Testing
@testable import MusicSample

/// Real songs: analyses cached by the app (a fixed set ships in Fixtures), every tail
/// paired with every head, each plan checked against the rules any plan must keep.
@Suite struct CorpusTests {
    struct Stats: CustomStringConvertible {
        var pairs = 0, matched = 0, blends = 0, gaps = 0, underVoice = 0, layered = 0
        var fades: [Double] = []
        var broken: [String: [String]] = [:]

        var description: String {
            let f = fades.sorted()
            func q(_ p: Double) -> String { f.isEmpty ? "-" : String(format: "%.1f", f[Int(Double(f.count - 1) * p)]) }
            let rules = broken.map { "  \($0.key): \($0.value.count) e.g. \($0.value.prefix(2).joined(separator: "; "))" }.sorted()
            return """
            \(pairs) pairs: \(matched) beat-matched, \(blends) blends, \(gaps) gaps; \(layered) layered; \(underVoice) start under a voice
            overlap fade s (p10/p50/p90/max): \(q(0.1))/\(q(0.5))/\(q(0.9))/\(q(1))
            \(broken.isEmpty ? "no rule broken" : "rules broken:\n" + rules.joined(separator: "\n"))
            """
        }
    }

    static func sweep(tails: [Fixtures.Clip], heads: [Fixtures.Clip], limit: Int = .max,
                      kinds: (outgoing: SongKind, incoming: SongKind) = (.regular, .regular)) -> Stats {
        var s = Stats()
        var pairs: [(Fixtures.Clip, Fixtures.Clip)] = []
        for t in tails { for h in heads where h.id != t.id { pairs.append((t, h)) } }
        if pairs.count > limit {
            var rng = SplitMix64(42)
            pairs.shuffle(using: &rng)
            pairs = Array(pairs.prefix(limit))
        }
        for (t, h) in pairs {
            let length = Fixtures.length(of: t.analysis)
            let p = TransitionPlanner.plan(tail: t.analysis, length: length, head: h.analysis, fallbackFade: 6, kinds: kinds)
            s.pairs += 1
            if p.matched { s.matched += 1 } else if p.fade > 0 { s.blends += 1 } else { s.gaps += 1 }
            if p.fade > 0 { s.fades.append(p.fade) }
            if p.layered { s.layered += 1 }
            if p.fade > 0, let v = t.analysis.voiceEnd, p.outAt < v - 0.5 { s.underVoice += 1 }
            for rule in violations(p, tail: t.analysis, head: h.analysis, length: length, kinds: kinds) {
                let key = rule.components(separatedBy: CharacterSet.decimalDigits.union(.init(charactersIn: ".-"))).joined()
                s.broken[key, default: []].append("\(t.id)>\(h.id): \(rule)")
            }
        }
        return s
    }

    @Test func fixturesLoad() {
        let f = Fixtures.bundled
        #expect(f.tails.count >= 10 && f.heads.count >= 10)
        for c in f.tails + f.heads {
            let a = c.analysis
            #expect(a.loudness.count == a.onset.count && a.onset.count == a.bass.count, "\(c.id) arrays differ")
            #expect(a.beats == a.beats.sorted(), "\(c.id) beats out of order")
            #expect(a.bpm >= 80 && a.bpm < 160, "\(c.id) bpm \(a.bpm)")
        }
    }

    @Test func fixturePairsKeepTheRules() {
        let f = Fixtures.bundled
        let s = Self.sweep(tails: f.tails, heads: f.heads)
        print("Fixture corpus, regular:\n\(s)")
        #expect(s.pairs > 50)
        #expect(s.broken.isEmpty, "\(s)")
        #expect(s.matched > 0, "no fixture pair beat-matched")
    }

    @Test(arguments: [(SongKind.unplugged, SongKind.regular), (.regular, .unplugged), (.altered, .regular), (.regular, .altered)])
    func fixturePairsKeepKindRules(out: SongKind, inn: SongKind) {
        let f = Fixtures.bundled
        let s = Self.sweep(tails: f.tails, heads: f.heads, kinds: (out, inn))
        #expect(s.broken.isEmpty, "\(s)")
        #expect(s.matched == 0)
    }

    @Test func fixturePlansAreDeterministic() throws {
        let f = Fixtures.bundled
        for t in f.tails.prefix(4) {
            for h in f.heads.prefix(4) {
                let a = TransitionPlanner.plan(tail: t.analysis, length: Fixtures.length(of: t.analysis), head: h.analysis, fallbackFade: 6)
                let b = TransitionPlanner.plan(tail: t.analysis, length: Fixtures.length(of: t.analysis), head: h.analysis, fallbackFade: 6)
                let enc = JSONEncoder()
                enc.outputFormatting = .sortedKeys
                let ea = try enc.encode(a), eb = try enc.encode(b)
                #expect(ea == eb)
            }
        }
    }

    /// Real outgoing songs whose bar phase changes when the beats the tracker carried
    /// into their closing silence are left out: none should.
    static func phaseFlips(_ clips: [Fixtures.Clip]) -> (silent: Int, flipped: [String]) {
        func downs(_ a: BeatAnalysis) -> Set<Int> {
            Set(stride(from: a.downbeatOffset, to: a.beats.count, by: 4).map { Int((a.beats[$0] * 1000).rounded()) })
        }
        var silent = 0
        var flipped: [String] = []
        for c in clips {
            guard let last = TransitionPlanner.lastLoud(c.analysis) else { continue }
            var trimmed = c.analysis
            trimmed.beats = c.analysis.beats.filter { $0 <= last }
            guard trimmed.beats.count < c.analysis.beats.count else { continue }
            silent += 1
            if downs(trimmed).isDisjoint(with: downs(c.analysis)) { flipped.append(c.id) }
        }
        return (silent, flipped)
    }

    @Test func barPhaseOfRealSongsIgnoresClosingSilence() {
        var clips = Fixtures.bundled.tails
        if FileManager.default.fileExists(atPath: Fixtures.userCache.path) { clips = Fixtures.load(from: Fixtures.userCache).tails }
        let r = Self.phaseFlips(clips)
        print("Bar phase: \(clips.count) outgoing songs, \(r.silent) with beats tracked into closing silence, \(r.flipped.count) change phase without them")
        #expect(r.flipped.isEmpty, "\(r.flipped.count) songs, e.g. \(r.flipped.prefix(5))")
    }

    /// The whole local cache (hundreds of songs), sampled. Skipped on machines without it.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: Fixtures.userCache.path)))
    func userCacheKeepsTheRules() {
        let all = Fixtures.load(from: Fixtures.userCache)
        let limit = Int(ProcessInfo.processInfo.environment["TIDE_CORPUS_PAIRS"] ?? "") ?? 3000
        let s = Self.sweep(tails: all.tails, heads: all.heads, limit: limit)
        print("User cache corpus (\(all.tails.count) tails, \(all.heads.count) heads), regular:\n\(s)")
        #expect(s.broken.isEmpty, "\(s)")
    }
}
