import Accelerate
import AVFoundation
import Foundation
import TandemCore
import TandemMedia

/// The mix's loudness at one moment of the timeline.
public struct LoudnessPoint: Codable, Equatable, Sendable {
    public var time: Time
    /// The 400 ms centred on `time`, in LUFS. Nil when it's silent (under
    /// -70 LUFS, where EBU R128 stops counting).
    public var momentaryLUFS: Double?
    /// The 3 s centred on `time`, in LUFS, or nil when silent.
    public var shortTermLUFS: Double?
    /// The highest sample in the momentary window, in dBFS.
    public var peakDBFS: Double?

    public init(time: Time, momentaryLUFS: Double?, shortTermLUFS: Double?, peakDBFS: Double?) {
        self.time = time
        self.momentaryLUFS = momentaryLUFS
        self.shortTermLUFS = shortTermLUFS
        self.peakDBFS = peakDBFS
    }
}

/// The mix's loudness over part of the timeline, as the timeline plays it:
/// before export's master gain and limiter, which move the whole range by
/// the same amount (bar the limited peaks).
public struct MixLoudness: Codable, Equatable, Sendable {
    public var start: Time
    public var end: Time
    public var step: Time
    /// From `start` to `end` every `step`, both ends included.
    public var points: [LoudnessPoint]
    /// Gated integrated loudness of `start` to `end`, or nil when silent.
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double?

    public init(start: Time, end: Time, step: Time, points: [LoudnessPoint], integratedLUFS: Double?, truePeakDBTP: Double?) {
        self.start = start
        self.end = end
        self.step = step
        self.points = points
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
    }
}

/// Where a track's rendered level left its gain lane.
public struct GainMismatch: Codable, Equatable, Sendable {
    public var start: Time
    public var end: Time
    /// At the worst moment: the gain the lane gives, and the gain heard,
    /// in dB.
    public var expectedDB: Double
    public var measuredDB: Double

    public init(start: Time, end: Time, expectedDB: Double, measuredDB: Double) {
        self.start = start
        self.end = end
        self.expectedDB = expectedDB
        self.measuredDB = measuredDB
    }
}

/// How closely one audio track's render followed its gain lane: the clip
/// levelling, gain, gain keyframes and fades the plan gives it.
public struct GainFollow: Codable, Equatable, Sendable {
    public var trackID: String
    public var track: String
    /// Seconds of sound compared. Silence, and crossfades where two clips
    /// on the track overlap, can't be compared and are left out.
    public var compared: Double
    /// When the heard gain lines up best with the lane shifted later, by
    /// this many seconds (negative: earlier). Nil when it lines up as it
    /// is, or the lane has no changes to line up.
    public var lateBy: Double?
    /// The biggest difference between lane and render, in dB.
    public var worstDB: Double?
    /// Stretches where the render is more than the tolerance off the lane.
    public var mismatches: [GainMismatch]

    public init(trackID: String, track: String, compared: Double, lateBy: Double?, worstDB: Double?, mismatches: [GainMismatch]) {
        self.trackID = trackID
        self.track = track
        self.compared = compared
        self.lateBy = lateBy
        self.worstDB = worstDB
        self.mismatches = mismatches
    }

    /// Compares the heard gain with the lane, block by block (dB, nil where
    /// a block can't be compared). `start` is the first block's time.
    static func compare(
        expected: [Double?], measured: [Double?], start: Double, block: Double, tolerance: Double
    ) -> (lateBy: Double?, worst: Double?, mismatches: [GainMismatch], compared: Int) {
        let count = min(expected.count, measured.count)
        var worst: Double?
        var compared = 0
        for i in 0..<count {
            guard let e = expected[i], let m = measured[i] else { continue }
            compared += 1
            worst = max(worst ?? 0, abs(m - e))
        }

        // Timing: the shift of the lane that best matches what's heard.
        // Only worth asking when the lane moves.
        var lateBy: Double?
        let values = expected.prefix(count).compactMap { $0 }
        if let low = values.min(), let high = values.max(), high - low >= 3 {
            func error(_ shift: Int) -> Double? {
                var total = 0.0, n = 0
                for i in 0..<count {
                    let j = i - shift
                    guard j >= 0, j < count, let e = expected[j], let m = measured[i] else { continue }
                    total += abs(m - e)
                    n += 1
                }
                return n > 0 ? total / Double(n) : nil
            }
            let reach = min(50, count / 2)
            if let unshifted = error(0) {
                var best = (shift: 0, error: unshifted)
                for shift in -reach...reach where shift != 0 {
                    if let e = error(shift), e < best.error { best = (shift, e) }
                }
                // A shift has to explain most of the difference, not shave
                // a little noise off a render that already follows.
                if best.shift != 0 && unshifted > 0.02 && best.error < unshifted * 0.5 {
                    lateBy = Double(best.shift) * block
                }
            }
        }

        // Runs of blocks off the lane, joined across gaps of up to 50 ms.
        var mismatches: [GainMismatch] = []
        var run: (first: Int, last: Int, worst: Int)?
        let joinGap = max(1, Int((0.05 / block).rounded()))
        func close() {
            guard let r = run, let e = expected[r.worst], let m = measured[r.worst] else { return }
            mismatches.append(GainMismatch(
                start: Time(seconds: start + Double(r.first) * block),
                end: Time(seconds: start + Double(r.last + 1) * block),
                expectedDB: e, measuredDB: m
            ))
            run = nil
        }
        for i in 0..<count {
            guard let e = expected[i], let m = measured[i], abs(m - e) > tolerance else { continue }
            if var r = run, i - r.last <= joinGap {
                r.last = i
                if let we = expected[r.worst], let wm = measured[r.worst], abs(m - e) > abs(wm - we) { r.worst = i }
                run = r
            } else {
                close()
                run = (i, i, i)
            }
        }
        close()
        return (lateBy, worst, mismatches, compared)
    }
}

/// Measures the mix as export reads it: the same composition, gain taps and
/// time-pitch algorithm, decoded from an AVAssetReader.
public enum MixMeter {
    /// EBU R128's sub-block: momentary loudness averages 4, short-term 30.
    static let blockSeconds = 0.1
    static let rate = Double(AudioBuffers.sampleRate)
    static let channels = AudioBuffers.channels

    /// The mix's loudness from `range.start` to `range.end` every `step`
    /// (rounded to a multiple of 100 ms). Reads 1.5 s either side, so the
    /// windows centred on the ends are whole.
    public static func measure(_ context: RenderContext, range: TimeRange, step: Time) async throws -> MixLoudness {
        let stepBlocks = max(1, Int((step.seconds / blockSeconds).rounded()))
        let (ready, _) = await ConvertedMedia.prepare(context)
        let built = try await CompositionAssembler.build(ready)
        let margin = 1.5
        let readFrom = range.start.seconds - margin
        let blockFrames = Int(rate * blockSeconds)
        let rangeFirst = Int((margin * rate).rounded())
        let rangeLast = rangeFirst + Int((range.duration.seconds * rate).rounded())

        var curveMeter = LoudnessMeter(sampleRate: rate, channels: channels)
        var rangeMeter = LoudnessMeter(sampleRate: rate, channels: channels)
        var blockPeaks: [Float] = []
        var blockPeak: Float = 0
        var blockFill = 0
        var frame = 0
        try await readMix(built, from: readFrom, to: range.end.seconds + margin) { samples in
            curveMeter.process(interleaved: samples)
            let frames = samples.count / channels
            // The part of this chunk inside the range, for its integrated
            // loudness and true peak.
            let inFirst = max(rangeFirst - frame, 0), inLast = min(rangeLast - frame, frames)
            if inFirst < inLast {
                rangeMeter.process(interleaved: Array(samples[(inFirst * channels)..<(inLast * channels)]))
            }
            var offset = 0
            samples.withUnsafeBufferPointer { pointer in
                while offset < frames {
                    let count = min(blockFrames - blockFill, frames - offset)
                    var peak: Float = 0
                    vDSP_maxmgv(pointer.baseAddress! + offset * channels, 1, &peak, vDSP_Length(count * channels))
                    blockPeak = max(blockPeak, peak)
                    blockFill += count
                    offset += count
                    if blockFill == blockFrames {
                        blockPeaks.append(blockPeak)
                        blockPeak = 0
                        blockFill = 0
                    }
                }
            }
            frame += frames
        }

        let energies = curveMeter.blockEnergies
        func lufs(_ first: Int, _ count: Int) -> Double? {
            guard first >= 0, first + count <= energies.count else { return nil }
            let mean = energies[first..<(first + count)].reduce(0, +) / Double(count)
            let value = LoudnessMeter.lufs(mean)
            return value > -70 ? value : nil
        }
        var points: [LoudnessPoint] = []
        let marginBlocks = Int((margin / blockSeconds).rounded())
        let lastBlock = Int((range.duration.seconds / blockSeconds + 1e-9).rounded(.down))
        var k = 0
        while k * stepBlocks <= lastBlock {
            let at = k * stepBlocks
            // Block `marginBlocks + at` starts at the point's time.
            let momentaryFirst = marginBlocks + at - 2
            let peak = momentaryFirst >= 0 && momentaryFirst + 4 <= blockPeaks.count
                ? blockPeaks[momentaryFirst..<(momentaryFirst + 4)].max() ?? 0 : 0
            points.append(LoudnessPoint(
                time: range.start + Time(seconds: Double(at) * blockSeconds),
                momentaryLUFS: lufs(momentaryFirst, 4),
                shortTermLUFS: lufs(marginBlocks + at - 15, 30),
                peakDBFS: peak > 0 ? 20 * log10(Double(peak)) : nil
            ))
            k += 1
        }
        let integrated = rangeMeter.integrated
        let truePeak = rangeMeter.truePeak
        return MixLoudness(
            start: range.start, end: range.end, step: Time(seconds: Double(stepBlocks) * blockSeconds), points: points,
            integratedLUFS: integrated.isFinite ? integrated : nil, truePeakDBTP: truePeak.isFinite ? truePeak : nil
        )
    }

    /// Checks that each track's render follows its gain lane over `range`.
    /// Each track is rendered on its own twice: as it is, and with every
    /// segment at a gain of 1. Their ratio, 10 ms at a time, is the gain the
    /// render applied, and the lane says what it should have been. So this
    /// catches a render that doesn't do what the lanes say (a ramp that
    /// lands late, a cut whose gain carries over), not a lane set wrong.
    public static func checkGains(_ context: RenderContext, range: TimeRange, trackIDs: [String], tolerance: Double = 1) async throws -> [GainFollow] {
        let block = 0.01
        let blockFrames = Int(rate * block)
        var results: [GainFollow] = []
        for id in trackIDs {
            guard let track = context.project.audioTracks.first(where: { $0.id == id }) else { continue }
            var solo = context
            solo.project = AudioLevels.soloing(context.project, audioTrackIDs: [id])
            let (ready, _) = await ConvertedMedia.prepare(solo)
            let built = try await CompositionAssembler.build(ready)
            var flatContext = ready
            flatContext.flatAudioGain = true
            let flat = try await CompositionAssembler.build(flatContext)
            let heard = try await blockEnergies(built, range: range, blockFrames: blockFrames)
            let plain = try await blockEnergies(flat, range: range, blockFrames: blockFrames)

            let gains = built.audioGains
            var expected: [Double?] = []
            var measured: [Double?] = []
            for i in 0..<min(heard.count, plain.count) {
                let blockStart = range.start.seconds + Double(i) * block
                // The lane's mean power gain over the block, unless two
                // segments overlap there (a crossfade), where the ratio of
                // the sums isn't any one gain.
                var power = 0.0
                var overlapped = false
                let samples = 8
                for s in 0..<samples {
                    let time = blockStart + (Double(s) + 0.5) * block / Double(samples)
                    let playing = gains.filter { $0.covers(time) }
                    if playing.count > 1 { overlapped = true }
                    let gain = Double(playing.first?.gain(at: time) ?? 0)
                    power += gain * gain
                }
                power /= Double(samples)
                // Below -60 dB (or a source at about -80 dBFS) the ratio is
                // mostly rounding.
                let usable = !overlapped && power > 1e-6 && plain[i] > 1e-8 * Double(blockFrames * channels)
                expected.append(usable ? 10 * log10(power) : nil)
                measured.append(usable && heard[i] > 0 ? 10 * log10(heard[i] / plain[i]) : (usable ? -120 : nil))
            }
            let result = GainFollow.compare(expected: expected, measured: measured, start: range.start.seconds, block: block, tolerance: tolerance)
            results.append(GainFollow(
                trackID: id, track: track.name, compared: Double(result.compared) * block,
                lateBy: result.lateBy, worstDB: result.worst, mismatches: Array(result.mismatches.prefix(10))
            ))
        }
        return results
    }

    /// The sum of squares of every sample in each `blockFrames` block of
    /// the mix over `range`.
    static func blockEnergies(_ built: BuiltComposition, range: TimeRange, blockFrames: Int) async throws -> [Double] {
        var energies: [Double] = []
        var sum = 0.0
        var fill = 0
        try await readMix(built, from: range.start.seconds, to: range.end.seconds) { samples in
            let frames = samples.count / channels
            var offset = 0
            samples.withUnsafeBufferPointer { pointer in
                while offset < frames {
                    let count = min(blockFrames - fill, frames - offset)
                    var squares: Float = 0
                    vDSP_svesq(pointer.baseAddress! + offset * channels, 1, &squares, vDSP_Length(count * channels))
                    sum += Double(squares)
                    fill += count
                    offset += count
                    if fill == blockFrames {
                        energies.append(sum)
                        sum = 0
                        fill = 0
                    }
                }
            }
        }
        return energies
    }

    /// Hands the mix from `from` to `to` (timeline seconds) to `chunk` as
    /// interleaved stereo float, every frame accounted for: silence before
    /// the timeline starts, after it ends and wherever nothing plays.
    static func readMix(_ built: BuiltComposition, from: Double, to: Double, chunk: ([Float]) -> Void) async throws {
        let total = Int(((to - from) * rate).rounded())
        guard total > 0 else { return }
        var consumed = 0
        func silence(upTo frame: Int) {
            while consumed < min(frame, total) {
                let count = min(4_800, min(frame, total) - consumed)
                chunk([Float](repeating: 0, count: count * channels))
                consumed += count
            }
        }
        let readStart = max(from, 0)
        let readEnd = min(to, built.duration.seconds)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        if !tracks.isEmpty, readEnd > readStart {
            let reader = try AVAssetReader(asset: built.composition)
            reader.timeRange = CMTimeRange(start: Time(seconds: readStart).cmTime, end: Time(seconds: readEnd).cmTime)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: AudioBuffers.readerSettings)
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? RenderError.export("couldn't read the mix") }
            while consumed < total, let buffer = output.copyNextSampleBuffer() {
                let position = Int(((CMSampleBufferGetPresentationTimeStamp(buffer).seconds - from) * rate).rounded())
                var samples = AudioBuffers.samples(in: buffer)
                silence(upTo: position)
                if position < consumed {
                    let skip = min(consumed - position, samples.count / channels)
                    samples.removeFirst(skip * channels)
                }
                let keep = min(samples.count / channels, total - consumed)
                if keep <= 0 { continue }
                if keep * channels < samples.count { samples.removeLast(samples.count - keep * channels) }
                chunk(samples)
                consumed += keep
            }
            // Only this thread reads, so stopping early is safe here.
            if reader.status == .reading { reader.cancelReading() }
            if reader.status == .failed { throw reader.error ?? RenderError.export("couldn't read the mix") }
        }
        silence(upTo: total)
    }
}

extension TrackGain {
    /// True when a segment plays at `time`.
    func covers(_ time: Double) -> Bool {
        pieces.withUnsafeBufferPointer { pieces in
            let index = Self.firstPiece(endingAfter: time, in: pieces)
            return index < pieces.count && time >= pieces[index].start
        }
    }
}

extension PlannedSegment {
    /// The segment at a gain of 1 throughout.
    var flattened: PlannedSegment {
        var copy = self
        if !copy.envelope.isEmpty {
            copy.envelope = [GainPoint(time: timeline.start, gain: 1), GainPoint(time: timeline.end, gain: 1)]
        }
        return copy
    }
}
