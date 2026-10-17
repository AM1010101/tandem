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

/// What counts as quiet, and as speech, in a take, from the frames read
/// around its cuts: its noise floor (the quietest tenth) and its loud
/// tenth, in each band.
///
/// Quiet is 10 dB over the floor, and never more than 25 dB under the loud
/// tenth in the full band, or 15 dB under it above 4 kHz. Breath, mouth
/// noise and room tone reach above 4 kHz too, and on the Tandem video
/// (October 2026) a high-band threshold set from the floor alone called
/// them voice at half the edges of an edit Mike had approved. Speech, the
/// level a clipped word has to reach to count, is within 20 dB of the loud
/// tenth in the full band and 10 dB above 4 kHz, where an "s" sits.
public struct SpeechLevels: Equatable, Sendable {
    /// Quiet is under these.
    public var full: Float
    public var high: Float
    /// Speech is at or over these.
    public var fullSpeech: Float
    public var highSpeech: Float
    /// The loud tenth above 4 kHz: a "k" or "t" released after its closure
    /// gets near it.
    public var highLoud: Float
    /// A take whose loud tenth is this quiet carries no voice (a screen
    /// recording's system sound, mostly digital silence), so its cuts
    /// aren't judged.
    public var isVoice: Bool

    static let overFloor: Float = 10
    static let quietUnderLoud: Float = 25
    static let highQuietUnderLoud: Float = 15
    static let speechUnderLoud: Float = 20
    static let highSpeechUnderLoud: Float = 10
    static let quietestVoice: Float = -60

    public init(full: Float, high: Float, fullSpeech: Float, highSpeech: Float, highLoud: Float, isVoice: Bool = true) {
        self.full = full
        self.high = high
        self.fullSpeech = fullSpeech
        self.highSpeech = highSpeech
        self.highLoud = highLoud
        self.isVoice = isVoice
    }

    /// Levels from every frame read of one take.
    public init(of readings: [SpeechEnergy]) {
        func spread(_ values: [Float]) -> (floor: Float, loud: Float) {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return (-120, -120) }
            return (sorted[sorted.count / 10], sorted[min(sorted.count - 1, sorted.count * 9 / 10)])
        }
        let full = spread(readings.flatMap(\.full))
        let high = spread(readings.flatMap(\.high))
        self.full = max(full.floor + Self.overFloor, full.loud - Self.quietUnderLoud)
        self.high = max(high.floor + Self.overFloor, high.loud - Self.highQuietUnderLoud)
        fullSpeech = max(self.full, full.loud - Self.speechUnderLoud)
        highSpeech = max(self.high, high.loud - Self.highSpeechUnderLoud)
        highLoud = high.loud
        isVoice = full.loud > Self.quietestVoice
    }
}

/// Whether a cut clips a word: does the voice run right up to the edit in
/// the file, or does the edit sit in a real pause?
///
/// A real pause is quiet for `minPause` or more in the full band and above
/// 4 kHz alike. Shorter quiet gaps are inside words (the closure before the
/// "k" of "takes"), so a cut in one still clips the word, and snapping a
/// cut to the quietest point near a word's end lands in one of those.
///
/// An edge out of a pause is only a clipped word when it's worth hearing:
/// at least `minSpeech` of speech-level voice on both sides (less on the
/// kept side is a fragment, less on the cut side a tail nobody misses),
/// and the edge not in a dip between two sounds. Fluent speech often has
/// no 80 ms pause between words, so a cut between them lands in a dip
/// (12 dB under the voice either side) and is fine; the exception is the
/// end of a clip in a closure, with the "k" or "t" released at speech
/// level right after it. On the Tandem video, an edit Mike approved, the
/// first version of this check flagged 144 of 758 edges; these rules leave
/// 6, each a cut through a sound.
public enum CutAudit {
    public static let minPause = 0.08
    /// How far an edge may move to reach a pause.
    public static let reach = 0.3
    /// How far into the pause a moved edge goes, so the word's tail (or the
    /// breath before the next one) isn't right on the cut.
    public static let pad = 0.04
    /// Voice at speech level a clipped word has on each side of the edge.
    public static let minSpeech = 0.05
    /// How far under the voice either side an edge is in a dip.
    static let dip: Float = 12
    /// How near the high band's loud tenth a release after a closure gets.
    static let release: Float = 8

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

        let reachFrames = Int((reach / step).rounded())
        /// Frames from `frame` going `direction`, up to a pause or `reach`.
        func stretch(_ frame: Int, _ direction: Int) -> [Int] {
            var frames: [Int] = []
            var index = frame
            while !isPause(index), frames.count < reachFrames {
                frames.append(index)
                index += direction
            }
            return frames
        }
        func speech(_ frames: [Int]) -> (full: Int, high: Int) {
            (frames.filter { energy.full[$0] >= levels.fullSpeech }.count, frames.filter { energy.high[$0] >= levels.highSpeech }.count)
        }
        let lostSpeech = speech(stretch(lostFrame, lostStep))
        let keptSpeech = speech(stretch(keptFrame, keptStep))
        let enough = Int((minSpeech / step).rounded())
        guard max(lostSpeech.full, lostSpeech.high) >= enough, max(keptSpeech.full, keptSpeech.high) >= enough else { return .clean }

        func level(_ frames: [Int], _ band: [Float]) -> Float {
            frames.filter { $0 >= 0 && $0 < count }.map { band[$0] }.max() ?? -120
        }
        let near = Int((0.1 / step).rounded())
        // Past the frames read is the file's start or end: silence.
        let edgeLevel = (before - 1...after + 1).map { $0 >= 0 && $0 < count ? energy.full[$0] : -120 }.min() ?? -120
        let keptPeak = level((0..<near).map { keptFrame + $0 * keptStep }, energy.full)
        let lostPeak = level((0..<near).map { lostFrame + $0 * lostStep }, energy.full)
        let inDip = edgeLevel <= min(keptPeak, lostPeak) - dip
        let released = side == .before && level((0..<3).map { lostFrame + $0 }, energy.high) >= levels.highLoud + release
        if inDip && !released { return .clean }

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

        var edge = Edge(
            clipped: true, kept: keptPause.distance, lost: lostPause.distance <= reach + 1e-9 ? lostPause.distance : nil,
            gap: gap, highBandOnly: lostSpeech.full == 0, pause: nil, suggestion: nil
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
