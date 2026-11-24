import Foundation
@testable import MusicSample

/// Deterministic noise for synthetic audio.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func noise() -> Float { Float.random(in: -1...1, using: &self) }
}

/// Synthetic drum tracks with known beat times, at the sample rate the tracker reads.
enum Synth {
    static let sr = BeatTracker.sampleRate

    struct Track {
        var samples: [Float]
        /// True beat times in clip seconds; index 0, 4, 8 ... are downbeats.
        var beats: [Double]
    }

    /// Kick on every beat (heavier on the one), snare on 2 and 4, hats on eighths and a
    /// quiet pad. Music runs from `musicFrom` to `musicUntil`; silence around it.
    static func drums(bpm: Double, seconds: Double = 75, firstBeat: Double = 0.25,
                      musicFrom: Double = 0, musicUntil: Double? = nil, bassFrom: Double = 0,
                      jitter: Double = 0, times: [Double]? = nil, soft: Bool = false, seed: UInt64 = 1) -> Track {
        var rng = SplitMix64(seed)
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        let end = musicUntil ?? seconds
        let period = 60 / bpm
        func add(at t: Double, length: Double, _ f: (Double) -> Float) {
            let i0 = Int(t * sr)
            let len = Int(length * sr)
            guard i0 < n else { return }
            for i in max(0, i0)..<min(n, i0 + len) { x[i] += f(Double(i - i0) / sr) }
        }
        var beats: [Double] = []
        var k = 0
        var t = firstBeat
        while times.map({ k < $0.count }) ?? (t < end - 0.05) {
            let bt = times?[k] ?? t + (jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) * period : 0)
            if bt >= musicFrom {
                beats.append(bt)
                let down = k % 4 == 0
                if bt >= bassFrom {
                    // Kick: falling sine sweep.
                    var phase = 0.0
                    let amp: Float = down ? 1.0 : 0.6
                    // Soft: a round 808-style kick that swells in over 25 ms, no click.
                    add(at: bt, length: soft ? 0.4 : 0.18) { s in
                        let f = soft ? 55 + 10 * exp(-s / 0.05) : 50 + 70 * exp(-s / 0.03)
                        phase += 2 * .pi * f / sr
                        let env = soft ? min(1, s / 0.025) * exp(-s / 0.15) : exp(-s / 0.07)
                        return amp * Float(sin(phase) * env)
                    }
                }
                var r = SplitMix64(rng.next())
                if !soft { add(at: bt, length: 0.006) { _ in 0.25 * r.noise() } }
                if k % 4 == 1 || k % 4 == 3 {
                    var r2 = SplitMix64(rng.next())
                    add(at: bt, length: 0.12) { s in 0.35 * r2.noise() * Float(exp(-s / 0.05)) }
                }
                for h in 0..<(soft ? 0 : 2) {
                    var r3 = SplitMix64(rng.next())
                    add(at: bt + Double(h) * period / 2, length: 0.03) { s in 0.06 * r3.noise() * Float(exp(-s / 0.01)) }
                }
            }
            k += 1
            t = firstBeat + Double(k) * period
        }
        let p0 = Int(musicFrom * sr), p1 = min(n, Int(end * sr))
        if p1 > p0 {
            for i in p0..<p1 {
                let s = Double(i) / sr
                x[i] += Float(0.04 * sin(2 * .pi * 220 * s) + 0.03 * sin(2 * .pi * 330 * s))
            }
        }
        return Track(samples: x, beats: beats)
    }

    /// The same drums on a tempo drifting `bpm` ± `depth` over `cycle`-second swings,
    /// like a band playing without a click. Music ends at `musicUntil`.
    static func wander(bpm: Double = 90, depth: Double = 15, cycle: Double = 20, seconds: Double = 75,
                       musicUntil: Double? = nil, seed: UInt64 = 1) -> Track {
        var times: [Double] = []
        var t = 0.3
        while t < (musicUntil ?? seconds) - 0.2 {
            times.append(t)
            t += 60 / (bpm + depth * sin(2 * .pi * t / cycle))
        }
        return drums(bpm: bpm, seconds: seconds, musicUntil: musicUntil, times: times, seed: seed)
    }

    static func noise(seconds: Double, amp: Float = 0.3, seed: UInt64 = 9) -> [Float] {
        var rng = SplitMix64(seed)
        return (0..<Int(seconds * sr)).map { _ in amp * rng.noise() }
    }
}

/// Hand-built analyses for planner tests: no audio, every field chosen.
enum Make {
    static let step = 256 / BeatTracker.sampleRate

    static func analysis(start: Double = 0, duration: Double = 75, bpm: Double = 128, firstBeat: Double = 0.5,
                         beatsUntil: Double? = nil, jitter: Double = 0, confidence: Double = 0.95,
                         downbeat: Int = 0, level: (Double) -> Float = { _ in -12 },
                         bassLevel: (Double) -> Float = { _ in -6 }, voiceEnd: Double? = nil,
                         seed: UInt64 = 3) -> BeatAnalysis {
        var rng = SplitMix64(seed)
        let frames = Int(duration / step)
        let period = 60 / bpm
        var beats: [Double] = []
        var t = firstBeat
        let until = beatsUntil ?? duration - 0.1
        while t < until {
            let j = jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) * period : 0
            beats.append(start + t + j)
            t += period
        }
        let times = (0..<frames).map { start + Double($0) * step }
        var onset = [Float](repeating: 0, count: frames)
        for (i, b) in beats.enumerated() {
            let f = Int(((b - start) / step).rounded())
            guard f >= 0, f < frames, level(b) > -60 else { continue }
            onset[f] = i % 4 == downbeat ? 4 : 2.5
        }
        var bass = times.map(bassLevel)
        // A bump at each downbeat, so the bar phase is findable from bass too.
        for (i, b) in beats.enumerated() where i % 4 == downbeat {
            let f = Int(((b - start) / step).rounded())
            if f >= 0, f < frames { bass[f] += 3 }
        }
        return BeatAnalysis(start: start, duration: duration, bpm: bpm, confidence: confidence, beats: beats,
                            loudness: times.map(level), loudnessStep: step, onset: onset, bass: bass,
                            voiceEnd: voiceEnd)
    }
}

/// How far apart the two songs' beats are, as heard, over a mix, using the true beat
/// times. Same formula as the player's log line in Stores.swift.
struct Drift {
    var offsets: [Double]
    var outIndex: Int
    var inIndex: Int
    var outError: Double
    var inError: Double
    var maxAbs: Double { offsets.map(abs).max() ?? .infinity }

    init?(plan: TransitionPlan, outBeats: [Double], inBeats: [Double], beats: Int) {
        guard let i0 = outBeats.indices.min(by: { abs(outBeats[$0] - plan.outAt) < abs(outBeats[$1] - plan.outAt) }),
              let j0 = inBeats.indices.min(by: { abs(inBeats[$0] - plan.inAt) < abs(inBeats[$1] - plan.inAt) }) else { return nil }
        outIndex = i0
        inIndex = j0
        outError = outBeats[i0] - plan.outAt
        inError = inBeats[j0] - plan.inAt
        let n = min(beats, outBeats.count - 1 - i0, inBeats.count - 1 - j0)
        guard n >= 0 else { return nil }
        offsets = (0...n).map { k in
            (outBeats[i0 + k] - plan.outAt) * plan.speed - (inBeats[j0 + k] - plan.inAt) / plan.incomingSpeed
        }
    }
}

enum Fixtures {
    struct Clip {
        let id: String
        let analysis: BeatAnalysis
    }

    static func load(from dir: URL) -> (tails: [Clip], heads: [Clip]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var tails: [Clip] = [], heads: [Clip] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // The app's cache names files `beats75c-<video id>-tail`; fixtures are `song-NN-tail`.
            let name = f.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("beats75c-") || name.hasPrefix("song-"), let data = try? Data(contentsOf: f),
                  let a = try? JSONDecoder().decode(BeatAnalysis.self, from: data) else { continue }
            let body = name.hasPrefix("beats75c-") ? name.dropFirst("beats75c-".count) : Substring(name)
            if body.hasSuffix("-tail") { tails.append(Clip(id: String(body.dropLast(5)), analysis: a)) }
            if body.hasSuffix("-head") { heads.append(Clip(id: String(body.dropLast(5)), analysis: a)) }
        }
        return (tails, heads)
    }

    static var bundled: (tails: [Clip], heads: [Clip]) {
        guard let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else { return ([], []) }
        return load(from: dir)
    }

    static var userCache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicApp/cache", isDirectory: true)
    }

    /// The song's length, from where its tail clip starts (the last 75 s).
    static func length(of tail: BeatAnalysis) -> TimeInterval {
        tail.start > 0 ? tail.start + 75 : tail.duration
    }
}

/// Everything a plan must satisfy whatever the songs. Returns the broken rules.
func violations(_ p: TransitionPlan, tail: BeatAnalysis, head: BeatAnalysis, length: TimeInterval,
                kinds: (outgoing: SongKind, incoming: SongKind)) -> [String] {
    var v: [String] = []
    let numbers = [p.outAt, p.inAt, p.fade, p.speed, p.incomingSpeed, p.beat, p.ringOut] + [p.swapDelay, p.outro, p.drop].compactMap { $0 }
    if numbers.contains(where: { !$0.isFinite }) { v.append("non-finite field") }
    if p.inAt < 0 { v.append("inAt \(p.inAt) < 0") }
    if p.fade < 0 { v.append("fade \(p.fade) < 0") }
    if p.ringOut < 0 { v.append("ringOut \(p.ringOut) < 0") }
    if p.outAt < tail.start - 0.07 { v.append("outAt \(p.outAt) before tail clip \(tail.start)") }
    if p.outAt + p.fade + p.ringOut > length + 0.07 { v.append("mix runs past song end: \(p.outAt + p.fade + p.ringOut) > \(length)") }
    if p.inAt > head.start + head.duration { v.append("inAt \(p.inAt) past head clip") }
    if p.matched {
        if !p.onBeat { v.append("matched but not onBeat") }
        // Each song bends by the square root of a gap up to 4%: 1.0198 up, but 0.9798 down.
        if abs(p.speed - 1) > 0.0205 { v.append("speed \(p.speed) bends more than 2%") }
        if abs(p.incomingSpeed - 1) > 0.0205 { v.append("incomingSpeed \(p.incomingSpeed) bends more than 2%") }
        if p.beat <= 0 { v.append("matched with beat \(p.beat)") }
        if p.fade < 6 - 1e-9 { v.append("matched fade \(p.fade) < 6") }
    } else {
        if p.speed != 1 || p.incomingSpeed != 1 { v.append("unmatched plan changes speed") }
    }
    if let s = p.swapDelay, s < 0 || s > p.fade + 1e-6 { v.append("swapDelay \(s) outside 0...fade \(p.fade)") }
    if kinds.outgoing == .unplugged || kinds.incoming == .unplugged {
        if p.fade != 0 || p.matched { v.append("unplugged song overlapped (fade \(p.fade), matched \(p.matched))") }
    }
    if kinds.outgoing == .altered || kinds.incoming == .altered, p.matched { v.append("altered song beat-matched") }
    return v
}
