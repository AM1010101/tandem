import Foundation

// The processing behind the compressor, limiter and voice clean-up audio
// effects. Written here rather than with Apple's AUDynamicsProcessor and
// AUPeakLimiter so it's the same on every Mac, can be tested sample by
// sample, and has a latency we know exactly (only the limiter's lookahead,
// which `AudioEffectChain` takes back out). The limiter is the master's
// `TruePeakLimiter`.
//
// Everything works on interleaved Float samples, with one gain shared by
// all channels so the stereo image doesn't move.

/// The level detector the compressor and expander share: the mean square
/// of the loudest channel over about 10 ms, in dB. Fast enough to see a
/// syllable, slow enough not to follow each cycle of a low voice.
struct LevelDetector {
    private let coefficient: Double
    private var meanSquare = 0.0

    init(sampleRate: Double, seconds: Double = 0.01) {
        coefficient = 1 - exp(-1 / (seconds * sampleRate))
    }

    mutating func level(_ frame: UnsafeMutableBufferPointer<Float>, base: Int, channels: Int) -> Double {
        var loudest = 0.0
        for c in 0..<channels {
            let x = Double(frame[base + c])
            loudest = max(loudest, x * x)
        }
        meanSquare += coefficient * (loudest - meanSquare)
        return 10 * log10(meanSquare + 1e-20)
    }
}

/// One-pole smoothing of a gain in dB, with separate times for the two
/// directions.
struct GainSmoother {
    private let down: Double
    private let up: Double
    private(set) var value = 0.0

    /// - Parameters:
    ///   - downSeconds: how fast it follows a gain that drops.
    ///   - upSeconds: how fast it follows a gain that rises.
    init(sampleRate: Double, downSeconds: Double, upSeconds: Double) {
        down = 1 - exp(-1 / (max(downSeconds, 1e-5) * sampleRate))
        up = 1 - exp(-1 / (max(upSeconds, 1e-5) * sampleRate))
    }

    mutating func follow(_ target: Double) -> Double {
        value += (target < value ? down : up) * (target - value)
        return value
    }
}

/// A feed-forward compressor with a soft knee. Over the threshold the level
/// rises 1 dB for every `ratio` dB in; attack and release are time
/// constants for the gain reduction. No lookahead, so no delay.
struct Compressor {
    let channels: Int
    let threshold: Double
    let ratio: Double
    let knee: Double
    let makeup: Double
    private var detector: LevelDetector
    private var smoother: GainSmoother

    init(channels: Int, sampleRate: Double = 48_000, thresholdDB: Double, ratio: Double,
         attackSeconds: Double, releaseSeconds: Double, kneeDB: Double = 6, makeupDB: Double = 0) {
        self.channels = channels
        self.threshold = thresholdDB
        self.ratio = max(ratio, 1)
        self.knee = max(kneeDB, 0)
        self.makeup = makeupDB
        detector = LevelDetector(sampleRate: sampleRate)
        smoother = GainSmoother(sampleRate: sampleRate, downSeconds: attackSeconds, upSeconds: releaseSeconds)
    }

    /// The gain change in dB (zero or less) the static curve asks for at
    /// `level`.
    func reduction(at level: Double) -> Double {
        let over = level - threshold
        let slope = 1 / ratio - 1
        if 2 * over < -knee { return 0 }
        if knee > 0, 2 * abs(over) <= knee {
            let x = over + knee / 2
            return slope * x * x / (2 * knee)
        }
        return slope * over
    }

    mutating func process(_ samples: UnsafeMutableBufferPointer<Float>, frames: Int) {
        for frame in 0..<frames {
            let base = frame * channels
            let level = detector.level(samples, base: base, channels: channels)
            let gain = pow(10, (smoother.follow(reduction(at: level)) + makeup) / 20)
            for c in 0..<channels {
                samples[base + c] = Float(Double(samples[base + c]) * gain)
            }
        }
    }
}

/// A downward expander for room noise: under the threshold the level falls
/// 3 dB for each dB the sound is under it, down to `range` dB of
/// reduction. It opens in 2 ms when the voice comes back and closes over
/// 150 ms, so word endings and the room's tail fade rather than chop.
struct Expander {
    static let ratio = 3.0
    let channels: Int
    let threshold: Double
    let range: Double
    private var detector: LevelDetector
    private var smoother: GainSmoother

    init(channels: Int, sampleRate: Double = 48_000, thresholdDB: Double, rangeDB: Double) {
        self.channels = channels
        self.threshold = thresholdDB
        self.range = max(rangeDB, 0)
        detector = LevelDetector(sampleRate: sampleRate)
        // Closing is a falling gain, opening a rising one.
        smoother = GainSmoother(sampleRate: sampleRate, downSeconds: 0.15, upSeconds: 0.002)
    }

    mutating func process(_ samples: UnsafeMutableBufferPointer<Float>, frames: Int) {
        guard range > 0 else { return }
        for frame in 0..<frames {
            let base = frame * channels
            let under = threshold - detector.level(samples, base: base, channels: channels)
            let target = under > 0 ? -min(range, under * (Self.ratio - 1)) : 0
            let gain = pow(10, smoother.follow(target) / 20)
            for c in 0..<channels {
                samples[base + c] = Float(Double(samples[base + c]) * gain)
            }
        }
    }
}

/// A 12 dB per octave Butterworth high-pass (the RBJ cookbook biquad), for
/// rumble, handling noise and the boom a room adds under a voice.
struct HighPass {
    let channels: Int
    private let b0, b1, b2, a1, a2: Double
    /// Per channel: the last two inputs and outputs.
    private var x1, x2, y1, y2: [Double]

    init(channels: Int, sampleRate: Double = 48_000, frequency: Double) {
        self.channels = channels
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * 0.5.squareRoot())
        let a0 = 1 + alpha
        b0 = (1 + cos(w)) / 2 / a0
        b1 = -(1 + cos(w)) / a0
        b2 = (1 + cos(w)) / 2 / a0
        a1 = -2 * cos(w) / a0
        a2 = (1 - alpha) / a0
        x1 = Array(repeating: 0, count: channels)
        x2 = x1
        y1 = x1
        y2 = x1
    }

    mutating func process(_ samples: UnsafeMutableBufferPointer<Float>, frames: Int) {
        for c in 0..<channels {
            var (p1, p2, q1, q2) = (x1[c], x2[c], y1[c], y2[c])
            for frame in 0..<frames {
                let i = frame * channels + c
                let x = Double(samples[i])
                let y = b0 * x + b1 * p1 + b2 * p2 - a1 * q1 - a2 * q2
                p2 = p1
                p1 = x
                q2 = q1
                q1 = y
                samples[i] = Float(y)
            }
            (x1[c], x2[c], y1[c], y2[c]) = (p1, p2, q1, q2)
        }
    }
}
