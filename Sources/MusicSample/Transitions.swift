import Accelerate
import Foundation

// Smart crossfades: the end of the playing song and the start of the next are
// listened to (beats and loudness) and the crossfade is planned from that: quiet
// tails and intros are skipped, the fade lasts a number of beats, and both songs
// meet on a beat. Classic beat tracking (onset envelope, autocorrelation tempo,
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
}

enum BeatTracker {
    static let sampleRate = 11025.0
    private static let frame = 1024
    private static let hop = 256

    static func analyze(_ samples: [Float], start: TimeInterval) -> BeatAnalysis? {
        guard samples.count > frame * 8 else { return nil }
        let fps = sampleRate / Double(hop)
        let (onset, loudness) = envelopes(samples)
        let bpm = tempo(onset, fps: fps)
        let confidence = steadiness(onset, fps: fps, bpm: bpm)
        let beats = track(onset, fps: fps, bpm: bpm).map { start + Double($0) / fps }
        return BeatAnalysis(start: start, duration: Double(samples.count) / sampleRate, bpm: bpm,
                            confidence: confidence, beats: beats, loudness: loudness, loudnessStep: 1 / fps)
    }

    /// Spectral flux of the log spectrum (how much new sound starts in each frame),
    /// and the loudness of each frame.
    private static func envelopes(_ x: [Float]) -> (onset: [Float], loudness: [Float]) {
        let log2n = vDSP_Length(log2(Double(frame)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = frame / 2
        var window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        var previous = [Float](repeating: 0, count: half)
        var onset: [Float] = []
        var loudness: [Float] = []
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
        return (detrended, loudness)
    }

    /// Three overlapping halves of the stretch, each timed on its own. The worst
    /// disagreement with the whole (half or double time folded away) sets the score:
    /// 1% off is 0.8, 5% off or worse is 0.
    private static func steadiness(_ env: [Float], fps: Double, bpm: Double) -> Double {
        let half = env.count / 2
        var worst = 0.0
        for part in 0..<3 {
            let from = part * half / 2
            var ratio = tempo(Array(env[from..<min(env.count, from + half)]), fps: fps) / bpm
            while ratio < 0.75 { ratio *= 2 }
            while ratio >= 1.5 { ratio /= 2 }
            worst = max(worst, abs(ratio - 1))
        }
        return max(0, 1 - worst * 20)
    }

    /// Strongest repetition in the onsets between 60 and 200 BPM, leaning toward
    /// 120 like listeners do.
    private static func tempo(_ env: [Float], fps: Double) -> Double {
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

/// Where the next song comes in, in both songs' own time.
struct TransitionPlan: Codable {
    /// The playing song's time at which the next one starts.
    var outAt: TimeInterval
    /// Where in the next song playback begins (past a quiet intro, on a beat).
    var inAt: TimeInterval
    var fade: TimeInterval
    /// Both songs had a beat steady enough to line up.
    var onBeat: Bool
}

enum TransitionPlanner {
    /// - Parameters:
    ///   - tail: the last stretch of the playing song; `length` is its full length.
    ///   - head: the first stretch of the next song.
    ///   - fallbackFade: the fade used when the beat isn't steady enough to count in.
    static func plan(tail: BeatAnalysis, length: TimeInterval, head: BeatAnalysis,
                     fallbackFade: TimeInterval) -> TransitionPlan {
        let steady = 0.9
        let onBeat = tail.confidence >= steady && head.confidence >= steady
        // Where the music really stops and starts: quieter than 20 dB under each
        // stretch's own loud level counts as silence or a fade.
        let endA = lastLoud(tail).map { min(length, $0 + 0.3) } ?? length
        let startB = firstLoud(head).map { max(0, min($0 - 0.05, 15)) } ?? 0
        var fade = onBeat ? min(10, max(4, 16 * 60 / tail.bpm)) : fallbackFade
        fade = min(fade, max(1, endA - tail.start - 1))
        var outAt = max(tail.start + 1, endA - fade)
        var inAt = startB
        if onBeat {
            if let beat = tail.beats.last(where: { $0 <= outAt + 0.05 }), outAt - beat < 60 / tail.bpm {
                outAt = beat
            }
            if let beat = head.beats.first(where: { $0 >= startB - 0.05 }), beat - startB < 60 / head.bpm {
                inAt = beat
            }
        }
        return TransitionPlan(outAt: outAt, inAt: inAt, fade: fade, onBeat: onBeat)
    }

    private static func threshold(_ a: BeatAnalysis) -> Float? {
        guard !a.loudness.isEmpty else { return nil }
        let sorted = a.loudness.sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.8)] - 20
    }

    private static func lastLoud(_ a: BeatAnalysis) -> TimeInterval? {
        guard let floor = threshold(a), let i = a.loudness.lastIndex(where: { $0 > floor }) else { return nil }
        return a.start + Double(i) * a.loudnessStep
    }

    private static func firstLoud(_ a: BeatAnalysis) -> TimeInterval? {
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
                DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
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
