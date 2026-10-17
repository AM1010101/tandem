import Accelerate
import AVFoundation
import Foundation

/// How loud a stretch of a file's sound is, in 10 ms frames: RMS in dB over
/// the full band, and again above 4 kHz.
///
/// The high band is there for the ends of words: a final "s" or "t" hardly
/// registers below 4 kHz, so a cut that only looks at the full band (or at
/// the cached waveform's peaks) can land after "take" and before its "s".
/// Agents who checked their own cuts (about 15 times, with ffmpeg RMS
/// envelopes) found the same: the cuts Mike heard clipped were the ones the
/// full band called quiet and the high band didn't.
public struct SpeechEnergy: Sendable {
    public static let frameSeconds = 0.01
    /// Where the high band starts.
    public static let highBand = 4000.0
    /// What a file is read at: high enough to keep an "s" (up to 16 kHz).
    static let readRate = 32_000.0

    /// Media time of the first frame.
    public var start: Double
    /// dB per frame, full band and above `highBand`.
    public var full: [Float]
    public var high: [Float]

    public init(start: Double, full: [Float], high: [Float]) {
        self.start = start
        self.full = full
        self.high = high
    }

    /// Frames of mono `samples` starting at media time `start`.
    public init(samples: [Float], sampleRate: Double, start: Double) {
        self.start = start
        let perFrame = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        let count = samples.count / perFrame
        let highPassed = Self.highBand < sampleRate * 0.45 ? Self.highPass(samples, sampleRate: sampleRate) : nil
        func levels(_ values: [Float]) -> [Float] {
            values.withUnsafeBufferPointer { buffer in
                (0..<count).map { frame in
                    var rms: Float = 0
                    vDSP_rmsqv(buffer.baseAddress! + frame * perFrame, 1, &rms, vDSP_Length(perFrame))
                    return rms > 1e-6 ? 20 * log10(rms) : -120
                }
            }
        }
        full = levels(samples)
        high = highPassed.map(levels) ?? [Float](repeating: -120, count: count)
    }

    /// Media time just past the last frame.
    public var end: Double { start + Double(full.count) * Self.frameSeconds }

    /// The frame holding media time `time` (may be outside the frames).
    public func index(of time: Double) -> Int {
        Int(((time - start) / Self.frameSeconds + 1e-6).rounded(.down))
    }

    /// Two second-order Butterworth high-passes at `highBand`, one after the
    /// other (what `highpass=f=4000,highpass=f=4000` does in ffmpeg), so the
    /// voice's harmonics under 4 kHz don't leak into the high band.
    static func highPass(_ samples: [Float], sampleRate: Double) -> [Float] {
        let w0 = 2 * Double.pi * highBand / sampleRate
        let alpha = sin(w0) / (2 * 0.5.squareRoot())
        let a0 = 1 + alpha
        let b0 = (1 + cos(w0)) / 2 / a0
        let b1 = -(1 + cos(w0)) / a0
        let b2 = b0
        let a1 = -2 * cos(w0) / a0
        let a2 = (1 - alpha) / a0
        var out = samples
        for _ in 0..<2 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in out.indices {
                let x = Double(out[i])
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x
                y2 = y1
                y1 = y
                out[i] = Float(y)
            }
        }
        return out
    }

    /// The file's sound from `from` to `to` (media time, as AVFoundation
    /// reads it), mixed to mono. Stops early at the end of the file.
    public static func read(url: URL, from: Double, to: Double) async throws -> SpeechEnergy {
        let start = max(0, from)
        guard to > start else { return SpeechEnergy(start: start, full: [], high: []) }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: to, preferredTimescale: 48_000))
        let reader = try await AudioReader(url: url, sampleRate: readRate, channels: 1, timeRange: range)
        let samples = try await Blocking.run(qos: .userInitiated) {
            var samples = [Float](repeating: 0, count: Int(((to - start) * readRate).rounded()))
            var reached = 0
            while try reader.next({ chunk, frames, stamp in
                // Placed by time stamp, like the waveform, so a file whose
                // sound starts late still lines up with media time.
                var position = Int(((stamp.seconds - start) * readRate).rounded())
                var offset = 0
                if position < 0 {
                    offset = min(frames, -position)
                    position += offset
                }
                let count = min(frames - offset, samples.count - position)
                guard count > 0 else { return }
                for i in 0..<count { samples[position + i] = chunk[offset + i] }
                reached = max(reached, position + count)
            }) {}
            return Array(samples.prefix(reached))
        }
        return SpeechEnergy(samples: samples, sampleRate: readRate, start: start)
    }
}

/// What counts as quiet in a take, in each band: 10 dB over its noise floor
/// (the quietest tenth of its frames), and never more than 30 dB under its
/// loud tenth, so digital silence doesn't drag it down to nothing. The same
/// rule `TranscriptAlignment` finds the voice with, so both agree on where
/// a word is.
public struct SpeechLevels: Equatable, Sendable {
    public var full: Float
    public var high: Float

    static let overFloor: Float = 10
    static let underLoud: Float = 30

    public init(full: Float, high: Float) {
        self.full = full
        self.high = high
    }

    /// Thresholds from every frame read of one take.
    public init(of readings: [SpeechEnergy]) {
        func threshold(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return -110 }
            let floor = sorted[sorted.count / 10]
            let loud = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
            return max(floor + Self.overFloor, loud - Self.underLoud)
        }
        full = threshold(readings.flatMap(\.full))
        high = threshold(readings.flatMap(\.high))
    }
}

/// Whether a cut clips a word: does the voice run right up to the edit in
/// the file, or does the edit sit in a real pause?
///
/// A real pause is quiet for `minPause` or more in the full band and above
/// 4 kHz alike. Shorter quiet gaps are inside words (the closure before the
/// "k" of "takes"), so a cut in one still clips the word, and snapping a
/// cut to the quietest point near a word's end lands in one of those.
public enum CutAudit {
    public static let minPause = 0.08
    /// How far an edge may move to reach a pause.
    public static let reach = 0.3
    /// How far into the pause a moved edge goes, so the word's tail (or the
    /// breath before the next one) isn't right on the cut.
    public static let pad = 0.04

    /// Which side of the edge the clip plays: `before` for a clip's end
    /// (it plays up to the edge), `after` for a clip's start.
    public enum Side: Sendable {
        case before, after
    }

    public struct Edge: Equatable, Sendable {
        public var clipped: Bool
        /// Seconds of voice on the kept side running up to the edge.
        public var kept: Double
        /// Seconds of voice past the edge, in the material cut away, before
        /// a pause. Nil when there's no pause within `reach`.
        public var lost: Double?
        /// The edge sits in a quiet gap this long, too short to be a pause.
        public var gap: Double?
        /// What's cut off is only heard above 4 kHz: an "s" or a "t".
        public var highBandOnly: Bool
        /// The pause the suggested edge goes into, in media time.
        public var pause: ClosedRange<Double>?
        /// Where to move the edge (media time): the nearest real pause
        /// within `reach`, either side.
        public var suggestion: Double?

        static let clean = Edge(clipped: false, kept: 0, lost: 0, gap: nil, highBandOnly: false, pause: nil, suggestion: nil)
    }

    public static func judge(_ energy: SpeechEnergy, levels: SpeechLevels, at time: Double, keeps side: Side) -> Edge {
        let count = energy.full.count
        let step = SpeechEnergy.frameSeconds
        let quiet = (0..<count).map { energy.full[$0] < levels.full && energy.high[$0] < levels.high }
        // Quiet runs long enough to be pauses. Beyond the frames read is the
        // file's start or end (reads reach well past every edge otherwise),
        // so it counts as a pause, and so does a run reaching it.
        let pauseFrames = Int((minPause / step).rounded())
        var inPause = [Bool](repeating: false, count: count)
        var runStart = 0
        for index in 0...count where index == count || !quiet[index] {
            if index > runStart, index - runStart >= pauseFrames || runStart == 0 || index == count {
                for k in runStart..<index { inPause[k] = true }
            }
            runStart = index + 1
        }
        func isPause(_ index: Int) -> Bool { index < 0 || index >= count || inPause[index] }
        func isQuiet(_ index: Int) -> Bool { index < 0 || index >= count || quiet[index] }

        let x = (time - energy.start) / step
        let before = Int((x - 1e-6).rounded(.up)) - 1
        let after = Int((x + 1e-6).rounded(.down))
        let (keptFrame, keptStep, lostFrame, lostStep) = side == .before ? (before, -1, after, 1) : (after, 1, before, -1)
        if isPause(keptFrame) || isPause(lostFrame) { return .clean }

        /// The first pause frame from `frame` going `direction`, and how far
        /// its near edge is from `time`.
        func nearestPause(from frame: Int, _ direction: Int) -> (frame: Int, distance: Double) {
            var index = frame
            while !isPause(index) { index += direction }
            let boundary = energy.start + Double(direction > 0 ? index : index + 1) * step
            return (index, abs(boundary - time))
        }
        let lostPause = nearestPause(from: lostFrame, lostStep)
        let keptPause = nearestPause(from: keptFrame, keptStep)

        var gap: Double?
        for frame in [keptFrame, lostFrame] where isQuiet(frame) {
            var low = frame, high = frame
            while !isPause(low - 1), isQuiet(low - 1) { low -= 1 }
            while !isPause(high + 1), isQuiet(high + 1) { high += 1 }
            gap = Double(high - low + 1) * step
            break
        }

        // What's cut off, up to the pause or `reach`: heard in the full band,
        // or only above 4 kHz?
        let reachFrames = Int((reach / step).rounded())
        var heardFull = false, heardHigh = false
        var index = lostFrame
        while index != lostPause.frame, abs(index - lostFrame) <= reachFrames {
            if index >= 0, index < count {
                if energy.full[index] >= levels.full { heardFull = true }
                if energy.high[index] >= levels.high { heardHigh = true }
            }
            index += lostStep
        }

        var edge = Edge(
            clipped: true, kept: keptPause.distance, lost: lostPause.distance <= reach + 1e-9 ? lostPause.distance : nil,
            gap: gap, highBandOnly: heardHigh && !heardFull, pause: nil, suggestion: nil
        )
        let options = [(lostPause, lostStep), (keptPause, keptStep)].filter { $0.0.distance <= reach + 1e-9 }
        guard let (pause, direction) = options.min(by: { $0.0.distance < $1.0.distance }) else { return edge }
        let range: ClosedRange<Double>
        if pause.frame < 0 {
            // Past the frames read: the file's start or end, of no known
            // length, so it's given room for the pad.
            range = (energy.start - 1)...energy.start
        } else if pause.frame >= count {
            range = energy.end...(energy.end + 1)
        } else {
            var low = pause.frame, high = pause.frame
            while low - 1 >= 0, inPause[low - 1] { low -= 1 }
            while high + 1 < count, inPause[high + 1] { high += 1 }
            range = (energy.start + Double(low) * step)...(energy.start + Double(high + 1) * step)
        }
        let pad = min(Self.pad, (range.upperBound - range.lowerBound) / 2)
        edge.pause = range
        edge.suggestion = direction > 0 ? range.lowerBound + pad : range.upperBound - pad
        return edge
    }
}
