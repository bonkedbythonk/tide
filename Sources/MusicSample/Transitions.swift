import Accelerate
import AVFoundation
import Foundation
import SoundAnalysis

// Smart crossfades: the end of the playing song and the start of the next are
// listened to (beats and loudness) and the crossfade is planned from that: quiet
// tails and intros are skipped, the fade lasts a number of beats, and both songs
// meet on a beat. When both beats are steady over the overlap and the tempos are
// within 2%, the plan is a beat-matched mix: the next song plays at the current one's
// tempo for up to 64 beats, and the bass swaps halfway. Classic beat tracking (onset envelope, autocorrelation tempo,
// dynamic-programming beats); a trained model can replace `BeatTracker` later.
// Nothing here depends on the rest of the app, so it can be tested on its own.

/// Beats and loudness of a stretch of audio. Times are in the song's own seconds.
struct BeatAnalysis: Codable {
    var start: TimeInterval
    var duration: TimeInterval
    var bpm: Double
    /// How steady the beat is, 0...1: the tempo of each part of the stretch measured
    /// on its own, against the whole. Near 1 for a drum machine, low for rubato piano.
    var confidence: Double
    var beats: [TimeInterval]
    /// Loudness in dB, one value every `loudnessStep` seconds from `start`.
    var loudness: [Float]
    var loudnessStep: TimeInterval
    /// Onset strength on the same steps, for timing a part of the stretch on its own.
    var onset: [Float]
    /// Energy below 150 Hz in dB on the same steps: kick and bass, for finding drops.
    var bass: [Float]
    /// Where the last singing, rapping or speech ends (own time), if any is heard.
    var voiceEnd: TimeInterval?
}

enum BeatTracker {
    static let sampleRate = 11025.0
    private static let frame = 1024
    private static let hop = 256

    static func analyze(_ samples: [Float], start: TimeInterval) -> BeatAnalysis? {
        guard samples.count > frame * 8 else { return nil }
        let fps = sampleRate / Double(hop)
        let (onset, loudness, bass) = envelopes(samples)
        // Tracked in 80-160: at half time the beats are far apart and the tracker's
        // picks wander tens of milliseconds, too loose to line two songs up.
        let bpm = foldTempo(tempo(onset, fps: fps))
        let confidence = steadiness(onset, fps: fps, bpm: bpm)
        let beats = track(onset, fps: fps, bpm: bpm).map { start + Double($0) / fps }
        return BeatAnalysis(start: start, duration: Double(samples.count) / sampleRate, bpm: bpm,
                            confidence: confidence, beats: beats, loudness: loudness, loudnessStep: 1 / fps,
                            onset: onset, bass: bass)
    }

    /// Spectral flux of the log spectrum (how much new sound starts in each frame),
    /// and the loudness of each frame.
    private static func envelopes(_ x: [Float]) -> (onset: [Float], loudness: [Float], bass: [Float]) {
        let log2n = vDSP_Length(log2(Double(frame)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], [], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = frame / 2
        var window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        var previous = [Float](repeating: 0, count: half)
        var onset: [Float] = []
        var loudness: [Float] = []
        var bass: [Float] = []
        let bassBins = Int(150 / (sampleRate / Double(frame)))
        var buffer = [Float](repeating: 0, count: frame)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var position = 0
        while position + frame <= x.count {
            x.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + position, 1, window, 1, &buffer, 1, vDSP_Length(frame))
            }
            var rms: Float = 0
            x.withUnsafeBufferPointer { src in vDSP_rmsqv(src.baseAddress! + position, 1, &rms, vDSP_Length(frame)) }
            loudness.append(20 * log10(rms + 1e-9))
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    buffer.withUnsafeBufferPointer { b in
                        b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            mags[0] = 0  // DC and Nyquist share this slot; neither says anything about beats
            var low: Float = 0
            for k in 1...bassBins { low += mags[k] * mags[k] }
            bass.append(10 * log10(low + 1e-9))
            var flux: Float = 0
            for k in 1..<half {
                let level = log1p(100 * mags[k])
                flux += max(0, level - previous[k])
                previous[k] = level
            }
            onset.append(flux)
            position += hop
        }
        if !onset.isEmpty { onset[0] = 0 }
        // Take away the slow trend so only the hits stand out, then scale to unit spread.
        let span = 16
        var detrended = onset
        for i in onset.indices {
            let lo = max(0, i - span), hi = min(onset.count, i + span + 1)
            let mean = onset[lo..<hi].reduce(0, +) / Float(hi - lo)
            detrended[i] = max(0, onset[i] - mean)
        }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(detrended, 1, nil, 1, &mean, &sd, vDSP_Length(detrended.count))
        if sd > 0 { detrended = detrended.map { $0 / sd } }
        return (detrended, loudness, bass)
    }

    /// Three overlapping halves of the stretch, each timed on its own. The worst
    /// disagreement with the whole (octaves and 3:2 triplet harmonics folded away) sets the score.
    private static func steadiness(_ env: [Float], fps: Double, bpm: Double) -> Double {
        let half = env.count / 2
        var worst = 0.0
        for part in 0..<3 {
            let from = part * half / 2
            let sub = Array(env[from..<min(env.count, from + half)])
            let t = tempo(sub, fps: fps)
            // Test 1:1, half-time, double-time, and 3:2 / 2:3 triplet/dotted harmonics:
            var minDiff = Double.infinity
            for factor in [0.5, 1.0, 2.0, 1.5, 2.0 / 3.0] {
                let ratio = t / (bpm * factor)
                minDiff = min(minDiff, abs(ratio - 1.0))
            }
            worst = max(worst, minDiff)
        }
        return max(0, 1 - worst * 10)
    }

    /// Strongest repetition in the onsets between 60 and 200 BPM, leaning toward
    /// 120 like listeners do.
    static func tempo(_ env: [Float], fps: Double) -> Double {
        let minLag = Int(fps * 60 / 200), maxLag = Int(fps * 60 / 60)
        guard env.count > maxLag * 2 else { return 120 }
        var energy: Float = 0
        vDSP_dotpr(env, 1, env, 1, &energy, vDSP_Length(env.count))
        guard energy > 0 else { return 120 }
        var corr = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var c: Float = 0
            env.withUnsafeBufferPointer { e in
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &c, vDSP_Length(env.count - lag))
            }
            corr[lag] = Double(c / energy)
        }
        var best = minLag, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120), 2))
            let score = corr[lag] * prior
            if score > bestScore { bestScore = score; best = lag }
        }
        // Parabolic interpolation for a tempo between whole lags.
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let a = corr[best - 1], b = corr[best], c = corr[best + 1]
            let d = a - 2 * b + c
            if d < 0 { lag += 0.5 * (a - c) / d }
        }
        return 60 * fps / lag
    }

    /// Beat positions (frame indices): the path through the onsets that lands on
    /// strong hits while keeping close to the tempo (Ellis, 2007).
    private static func track(_ env: [Float], fps: Double, bpm: Double) -> [Int] {
        let period = fps * 60 / bpm
        let tightness = 100.0
        var score = [Double](repeating: 0, count: env.count)
        var back = [Int](repeating: -1, count: env.count)
        let lo = Int((period / 2).rounded()), hi = Int((period * 2).rounded())
        for i in env.indices {
            var bestPrev = -1, bestVal = -Double.infinity
            if i >= lo {
                for j in max(0, i - hi)...(i - lo) {
                    let v = score[j] - tightness * pow(log(Double(i - j) / period), 2)
                    if v > bestVal { bestVal = v; bestPrev = j }
                }
            }
            score[i] = Double(env[i]) + (bestPrev >= 0 ? max(0, bestVal) : 0)
            back[i] = bestPrev >= 0 && bestVal > 0 ? bestPrev : -1
        }
        // End on the best-scoring frame within the last beat, then walk back.
        let tailStart = max(0, env.count - Int(period.rounded()))
        guard var i = (tailStart..<env.count).max(by: { score[$0] < score[$1] }) else { return [] }
        var beats: [Int] = []
        while i >= 0 {
            beats.append(i)
            i = back[i]
        }
        return beats.reversed()
    }
}

/// Half and double time are the same beat for mixing: tempos folded into 80-160.
func foldTempo(_ bpm: Double) -> Double {
    guard bpm > 0 else { return 0 }
    var b = bpm
    while b < 80 { b *= 2 }
    while b >= 160 { b /= 2 }
    return b
}

/// Finds the closest octave-equivalent speed ratio between two tempos.
/// Returns (speed, diff) if within maxDiff (default 2%), or nil.
func tempoMatch(bpmA: Double, bpmB: Double, maxDiff: Double = 0.02) -> (speed: Double, diff: Double)? {
    guard bpmA > 30, bpmB > 30 else { return nil }
    var bestSpeed = 1.0
    var bestDiff = Double.infinity
    // Test 1:1, half-time (1:2), and double-time (2:1):
    for k in [0.5, 1.0, 2.0] {
        let s = bpmA / (bpmB * k)
        let diff = abs(s - 1.0)
        if diff < bestDiff {
            bestDiff = diff
            bestSpeed = s
        }
    }
    guard bestDiff <= maxDiff else { return nil }
    return (speed: bestSpeed, diff: bestDiff)
}

/// Where the next song comes in, in both songs' own time.
struct TransitionPlan: Codable {
    /// The playing song's time at which the next one starts.
    var outAt: TimeInterval
    /// Where in the next song playback begins (past a quiet intro, on a beat).
    var inAt: TimeInterval
    var fade: TimeInterval
    /// Both songs had a beat steady enough to line up.
    var onBeat: Bool
    /// Beat-matched: the current song plays at 1 / `speed` during the overlap so its
    /// beats land on the next one's, and the bass swaps halfway. `fade` and `beat`
    /// are in the current song's own time.
    var matched = false
    var speed = 1.0
    /// The current song's beat length (s), for timing the bass swap and the ease back.
    var beat: TimeInterval = 0
    /// Where the sections were found (each song's own time), when they were.
    var outro: TimeInterval?
    var drop: TimeInterval?
    /// Seconds from `outAt` when the drop lands and bass swaps. Nil for default half-way.
    var swapDelay: TimeInterval?
}

extension BeatAnalysis {
    /// A track is steady if it has a clear, regular beat grid (Trance, Synthwave, Dance, Pop, Phonk).
    /// Tracks without regular beats (rubato piano covers, classical, acoustic solos) return false.
    var isSteady: Bool {
        if confidence >= 0.70 { return true }
        guard beats.count >= 20 else { return false }
        if let fit = TransitionPlanner.fit(beats), fit.jitter < 0.08 {
            return true
        }
        return false
    }

    /// Index (0...3) of the first downbeat in `beats` (Beat 1 of a 4-beat bar).
    /// Synthwave, phonk, dance and pop songs have a heavy kick and chord transient
    /// on beat 1. We test all 4 phase offsets and pick the one with maximum combined
    /// sub-150Hz bass energy and onset flux.
    var downbeatOffset: Int {
        guard beats.count >= 8, loudnessStep > 0 else { return 0 }
        let fps = 1 / loudnessStep
        var bestOffset = 0
        var bestScore = -Double.infinity
        for offset in 0..<4 {
            var sum = 0.0
            var count = 0
            var i = offset
            while i < beats.count {
                let frameIndex = Int(((beats[i] - start) * fps).rounded())
                if frameIndex >= 0 && frameIndex < bass.count {
                    let b = Double(bass[frameIndex])
                    let o = frameIndex < onset.count ? Double(onset[frameIndex]) : 0
                    sum += b + 2.0 * o
                    count += 1
                }
                i += 4
            }
            let avg = count > 0 ? sum / Double(count) : -Double.infinity
            if avg > bestScore {
                bestScore = avg
                bestOffset = offset
            }
        }
        return bestOffset
    }

    /// Snaps a beat index to the closest downbeat at or before `index`.
    func snapDownbeat(atOrBefore index: Int) -> Int {
        guard !beats.isEmpty else { return 0 }
        let off = downbeatOffset
        let idx = min(beats.count - 1, max(0, index))
        let rem = ((idx - off) % 4 + 4) % 4
        return max(0, idx - rem)
    }

    /// Snaps a beat index to the closest downbeat at or after `index`.
    func snapDownbeat(atOrAfter index: Int) -> Int {
        guard !beats.isEmpty else { return 0 }
        let off = downbeatOffset
        let idx = min(beats.count - 1, max(0, index))
        let rem = ((off - idx) % 4 + 4) % 4
        return min(beats.count - 1, idx + rem)
    }

    /// Sub-150Hz bass energy in dB at the given beat index.
    func bassEnergyAt(beat index: Int) -> Float {
        guard beats.indices.contains(index), loudnessStep > 0 else { return -100 }
        let fps = 1 / loudnessStep
        let frameIndex = Int(((beats[index] - start) * fps).rounded())
        guard frameIndex >= 0 && frameIndex < bass.count else { return -100 }
        return bass[frameIndex]
    }
}

enum TransitionPlanner {
    /// - Parameters:
    ///   - tail: the last stretch of the playing song; `length` is its full length.
    ///   - head: the first stretch of the next song.
    ///   - fallbackFade: the fade used when the beat isn't steady enough to count in.
    static func plan(tail: BeatAnalysis, length: TimeInterval, head: BeatAnalysis,
                     fallbackFade: TimeInterval) -> TransitionPlan {
        if let mix = matchedPlan(tail: tail, length: length, head: head) { return mix }
        
        // True end of audible sound in Song A (never cut off vocal outros or instrument decay):
        let endA = max(lastLoud(tail) ?? length, length - 1.0)
        // Song B starts from its very beginning (never skip into the track):
        let startB = min(firstLoud(head) ?? 0, 0.15)

        let rawLastA = tail.beats.lastIndex(where: { $0 <= endA }) ?? max(0, tail.beats.count - 1)
        let lastBeatA = tail.snapDownbeat(atOrBefore: rawLastA)
        let finalDownbeatA = !tail.beats.isEmpty ? tail.beats[lastBeatA] : (endA - 0.5)

        if tail.isSteady && head.isSteady {
            // Both steady, tempos too far apart to match without audible stretching:
            // a long blend over the end of the outgoing song, 32 beats (8 bars) kept to
            // 10-14 s, starting on a downbeat. The bass swaps halfway so the two kicks
            // are never both at full weight.
            let beatPeriod = 60.0 / tail.bpm
            let lengthBeats = min(14.0, max(10.0, 32 * beatPeriod)) / beatPeriod
            let rawStart = tail.beats.lastIndex(where: { $0 <= finalDownbeatA - lengthBeats * beatPeriod })
                ?? max(0, lastBeatA - Int(lengthBeats))
            let startIndex = tail.snapDownbeat(atOrBefore: rawStart)
            var outAt = max(tail.start + 1, tail.beats.isEmpty ? endA - 12 : tail.beats[startIndex])
            // Never fade a voice out mid-line: wait for the singing to stop (on the
            // next downbeat), keeping at least 6 s for the blend.
            if let voice = tail.voiceEnd, voice > outAt {
                let after = tail.beats.firstIndex(where: { $0 >= voice }).map { tail.beats[tail.snapDownbeat(atOrAfter: $0)] } ?? voice
                outAt = max(outAt, min(after, endA - 6))
            }
            let fade = endA - outAt
            return TransitionPlan(outAt: outAt, inAt: startB, fade: fade, onBeat: true,
                                  matched: false, beat: beatPeriod, swapDelay: fade / 2)
        } else {
            // Piano covers, rubato, acoustic solos, soundtracks (no steady drum beat):
            // No fade needed! The piano / acoustic piece plays 100% untouched to its natural end
            // (allowing closing chords and room reverb to decay completely without artificial volume reduction).
            // Next track starts cleanly right at endA at 100% volume with 0s overlap, skipping dead video air.
            let outAt = max(tail.start + 1, endA)
            return TransitionPlan(outAt: outAt, inAt: startB, fade: 0, onBeat: false,
                                  matched: false)
        }
    }

    /// A beat-matched mix, or nil when the beats aren't steady enough over the
    /// overlap or the tempos are too far apart (more than 2% after octave folding: more stretch wobbles).
    /// Apple Music / Spotify style 16 to 32 bar (18-30s) mix building Song B's intro under Song A!
    private static func matchedPlan(tail: BeatAnalysis, length: TimeInterval, head: BeatAnalysis) -> TransitionPlan? {
        guard tail.isSteady && head.isSteady else { return nil }
        guard let match = tempoMatch(bpmA: tail.bpm, bpmB: head.bpm, maxDiff: 0.02) else { return nil }

        let endA = max(lastLoud(tail) ?? length, length - 1.0)
        let startB = min(firstLoud(head) ?? 0, 0.15)
        guard let rawLast = tail.beats.lastIndex(where: { $0 <= endA }) else { return nil }
        let last = tail.snapDownbeat(atOrBefore: rawLast)

        let drop = dropAt(head, first: 0)
        let outro = outroStart(tail, last: last)

        // Prevent transition from invading the vocal chorus or main body of Song A:
        let maxMixBeats: Int
        if let outro {
            // Outro detected where energy drops: constrain mix to the true outro section
            maxMixBeats = max(16, min(64, ((last - outro + 4) / 16) * 16))
        } else {
            maxMixBeats = 48
        }

        var candidates: [(startA: Int, count: Int, swapBeats: Int)] = []

        // If Song B has a detected drop within the outro window:
        if let drop, drop >= 16 && drop <= maxMixBeats {
            let dropPhrase = (drop / 16) * 16
            candidates.append((startA: last - dropPhrase, count: dropPhrase + 16, swapBeats: dropPhrase))
        }

        // Standard phrase automix (64, 48, 32, 16 beats) capped to available outro beats:
        for count in [64, 48, 32, 16].filter({ $0 <= maxMixBeats }) {
            candidates.append((startA: last - count, count: count, swapBeats: max(1, count - 16)))
        }

        for cand in candidates {
            guard cand.startA >= 0, cand.startA + cand.count < tail.beats.count else { continue }
            guard cand.count < head.beats.count else { continue }

            let a = Array(tail.beats[cand.startA...(cand.startA + cand.count)])
            let b = Array(head.beats[0...min(cand.count, head.beats.count - 1)])

            guard let fitA = fit(a), fitA.jitter < 0.06,
                  let fitB = fit(b), fitB.jitter < 0.06 else { continue }
            guard onHits(tail, a), onHits(head, b) else { continue }

            let outAt = a[0]
            if let voice = tail.voiceEnd, outAt < voice - 0.5 { continue }
            let fade = endA - outAt
            guard fade >= 10.0 && fade <= 35.0 else { continue }

            let swapDelay = Double(cand.swapBeats) * fitA.period
            return TransitionPlan(outAt: outAt, inAt: startB, fade: fade, onBeat: true,
                                  matched: true, speed: match.speed, beat: fitA.period,
                                  outro: outroStart(tail, last: last).map { tail.beats[$0] },
                                  drop: drop.map { head.beats[$0] },
                                  swapDelay: swapDelay)
        }
        return nil
    }

    /// Bar-sized steps (4 beats) through a stretch, compared against the next on loudness and bass.
    private static func energy(_ a: BeatAnalysis, _ from: TimeInterval, _ to: TimeInterval) -> Float {
        let fps = 1 / a.loudnessStep
        let lo = max(0, Int((from - a.start) * fps)), hi = min(a.loudness.count, Int((to - a.start) * fps))
        guard hi > lo else { return -120 }
        var sum: Float = 0
        for i in lo..<hi { sum += (a.loudness[i] + a.bass[i]) / 2 }
        return sum / Float(hi - lo)
    }

    /// The outgoing song's outro: the latest point, counted back in 2-bar steps from its
    /// last downbeat, where the music gets clearly lighter (4 dB) for the bars after.
    static func outroStart(_ a: BeatAnalysis, last: Int) -> Int? {
        var k = last - 16
        while k >= 16 {
            let before = energy(a, a.beats[k - 16], a.beats[k])
            let after = energy(a, a.beats[k], a.beats[min(last, k + 16)])
            if before - after > 4 { return k }
            k -= 8
        }
        return nil
    }

    /// The next song's drop: the first point, in 2-bar steps from its first downbeat, where the
    /// music gets clearly fuller (4 dB) than the bars before.
    static func dropAt(_ a: BeatAnalysis, first: Int) -> Int? {
        var k = first + 16
        while k + 16 < a.beats.count {
            let before = energy(a, a.beats[k - 16], a.beats[k])
            let after = energy(a, a.beats[k], a.beats[k + 16])
            if after - before > 4 { return k }
            k += 8
        }
        return nil
    }

    /// The beat length from a straight line through the beat times, and how far the
    /// beats wander from that line (s, root mean square).
    static func fit(_ beats: [TimeInterval]) -> (period: TimeInterval, jitter: TimeInterval)? {
        let n = Double(beats.count)
        guard beats.count >= 8 else { return nil }
        let meanI = (n - 1) / 2
        let meanT = beats.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, t) in beats.enumerated() {
            num += (Double(i) - meanI) * (t - meanT)
            den += pow(Double(i) - meanI, 2)
        }
        let period = num / den
        guard period > 0 else { return nil }
        let rms = sqrt(beats.enumerated().map { i, t in pow(t - (meanT + (Double(i) - meanI) * period), 2) }.reduce(0, +) / n)
        return (period, rms)
    }

    /// Most beats (35% or more) sit on a real hit. Even when drums thin out in an outro,
    /// the tracked beat tempo remains valid.
    static func onHits(_ a: BeatAnalysis, _ beats: [TimeInterval]) -> Bool {
        let fps = 1 / a.loudnessStep
        let hits = beats.filter { t in
            let i = Int(((t - a.start) * fps).rounded())
            let near = max(0, i - 1)...min(a.onset.count - 1, i + 1)
            return near.contains { a.onset[$0] > 0.20 }
        }
        return Double(hits.count) >= Double(beats.count) * 0.35
    }

    private static func threshold(_ a: BeatAnalysis) -> Float? {
        guard !a.loudness.isEmpty else { return nil }
        let sorted = a.loudness.sorted()
        let loud = sorted[Int(Double(sorted.count - 1) * 0.8)]
        // True silence is below -48 dBFS, or 38 dB below loud passages.
        // This ensures vocal outros, quiet acoustic instruments, and decay tails are never treated as silence.
        return min(-48.0, loud - 38.0)
    }

    static func lastLoud(_ a: BeatAnalysis) -> TimeInterval? {
        guard let floor = threshold(a), let i = a.loudness.lastIndex(where: { $0 > floor }) else { return nil }
        return a.start + Double(i) * a.loudnessStep
    }

    static func firstLoud(_ a: BeatAnalysis) -> TimeInterval? {
        guard let floor = threshold(a), let i = a.loudness.firstIndex(where: { $0 > floor }) else { return nil }
        return a.start + Double(i) * a.loudnessStep
    }
}

/// Decodes part of a stream to mono samples with ffmpeg (YouTube's Opus audio
/// isn't something AVFoundation reads). Nil when ffmpeg isn't installed.
enum AudioClip {
    static let ffmpeg: URL? = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    static func decode(_ url: URL, from start: TimeInterval, seconds: TimeInterval) async -> [Float]? {
        guard let ffmpeg else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = ffmpeg
                process.qualityOfService = .utility
                process.arguments = ["-nostdin", "-loglevel", "error", "-ss", String(format: "%.2f", max(0, start)),
                                     "-t", String(format: "%.2f", seconds), "-i", url.absoluteString,
                                     "-ac", "1", "-ar", String(Int(BeatTracker.sampleRate)), "-f", "f32le", "-"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                // A stalled download shouldn't hold the analysis forever.
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: deadline)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                guard process.terminationStatus == 0, data.count >= 4 else { return continuation.resume(returning: nil) }
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                continuation.resume(returning: samples)
            }
        }
    }
}

/// Hears where voices are, with the sound classifier built into macOS (on device,
/// a fraction of a second for a 75 s clip).
enum VoiceDetector {
    private final class Collector: NSObject, SNResultsObserving {
        var last: TimeInterval?
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            let voice = ["singing", "rapping", "speech", "choir_singing"]
                .compactMap { r.classification(forIdentifier: $0)?.confidence }.max() ?? 0
            if voice >= 0.15 { last = r.timeRange.end.seconds }
        }
    }

    /// End of the last 1.5 s window with a voice in it, in the clip's own time.
    static func lastVoice(_ samples: [Float], sampleRate: Double, start: TimeInterval) -> TimeInterval? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 1000)
        request.overlapFactor = 0
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let collector = Collector()
        guard (try? analyzer.add(request, withObserver: collector)) != nil else { return nil }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return collector.last.map { start + $0 }
    }
}
