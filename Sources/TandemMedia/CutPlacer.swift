import Foundation

/// Where a cut's edge can go in a file's sound: the real pauses near it,
/// how clean a join there is, and the moves that put a clipped edge in a
/// pause without bringing a cut word back or dropping a kept one.
///
/// `CutAudit` (`tandem check --cuts`) judges every cut with it, and it's
/// meant to be the one cut placer, so commands that plan cuts pause to
/// pause can place them the same way.
public struct CutPlacer: Sendable {
    public let energy: SpeechEnergy
    public let levels: SpeechLevels
    /// Per frame: quiet in both bands, and part of a real pause.
    private let quiet: [Bool]
    private let inPause: [Bool]

    private static let step = SpeechEnergy.frameSeconds

    public init(_ energy: SpeechEnergy, levels: SpeechLevels) {
        self.energy = energy
        self.levels = levels
        let count = energy.full.count
        let quiet = (0..<count).map { energy.full[$0] < levels.full && energy.high[$0] < levels.high }
        // Quiet runs long enough to be pauses. Beyond the frames read is the
        // file's start or end (reads reach well past every edge otherwise),
        // so it counts as a pause, and so does a run reaching it.
        let pauseFrames = Int((CutAudit.minPause / Self.step).rounded())
        var inPause = [Bool](repeating: false, count: count)
        var runStart = 0
        for index in 0...count where index == count || !quiet[index] {
            if index > runStart, index - runStart >= pauseFrames || runStart == 0 || index == count {
                for k in runStart..<index { inPause[k] = true }
            }
            runStart = index + 1
        }
        self.quiet = quiet
        self.inPause = inPause
    }

    func isPause(_ index: Int) -> Bool { index < 0 || index >= inPause.count || inPause[index] }
    func isQuiet(_ index: Int) -> Bool { index < 0 || index >= quiet.count || quiet[index] }

    /// The pause holding frame `index`, in media time.
    public func pause(at index: Int) -> ClosedRange<Double> {
        let count = inPause.count
        // Past the frames read: the file's start or end, of no known length,
        // so it's given room for the pad.
        if index < 0 { return (energy.start - 1)...energy.start }
        if index >= count { return energy.end...(energy.end + 1) }
        var low = index, high = index
        while low - 1 >= 0, inPause[low - 1] { low -= 1 }
        while high + 1 < count, inPause[high + 1] { high += 1 }
        return (energy.start + Double(low) * Self.step)...(energy.start + Double(high + 1) * Self.step)
    }

    /// How a join sounds from one side: the clip's 25 ms beside the edge
    /// against the speech around it.
    public struct JoinScore: Equatable, Sendable {
        /// Level of the clip's 25 ms beside the edge, dB.
        public var keptDB: Float
        /// The speech level: the loud end of 3 s either side, dB.
        public var speechDB: Float
        /// How far the clip's side is under the speech: 15 dB or more is a
        /// clean join, under 9 a clipped one.
        public var margin: Float { speechDB - keptDB }
    }

    public func score(at time: Double, keeps side: CutAudit.Side) -> JoinScore {
        let step = Self.step
        let span = side == .before ? (time - CutAudit.keptSpan)...time : time...(time + CutAudit.keptSpan)
        // Power over the span, each frame by how much of it is in the span.
        // Past the frames read is the file's start or end: silence.
        var power = 0.0
        let first = Int(((span.lowerBound - energy.start) / step).rounded(.down))
        let last = Int(((span.upperBound - energy.start) / step - 1e-9).rounded(.down))
        for index in first...max(first, last) where index >= 0 && index < energy.full.count {
            let from = max(span.lowerBound, energy.start + Double(index) * step)
            let to = min(span.upperBound, energy.start + Double(index + 1) * step)
            if to > from { power += pow(10, Double(energy.full[index]) / 10) * (to - from) }
        }
        let kept = power > 0 ? max(-120, Float(10 * log10(power / CutAudit.keptSpan))) : -120
        let low = max(0, energy.index(of: time - CutAudit.speechSpan))
        let high = min(energy.full.count, energy.index(of: time + CutAudit.speechSpan))
        let around = low < high ? energy.full[low..<high].sorted() : []
        let speech = around.isEmpty ? -120 : around[min(around.count - 1, Int(Double(around.count) * CutAudit.speechPercentile))]
        return JoinScore(keptDB: kept, speechDB: speech)
    }

    /// The frames from one beside an edge, going away from it, up to the
    /// first frame of a pause.
    struct Run {
        var frames: [Int]
        var pause: Int
        /// Seconds from the edge to the pause.
        var distance: Double
    }

    func run(from frame: Int, _ direction: Int, edge time: Double) -> Run {
        var frames: [Int] = []
        var index = frame
        while !isPause(index) {
            frames.append(index)
            index += direction
        }
        let boundary = energy.start + Double(direction > 0 ? index : index + 1) * Self.step
        return Run(frames: frames, pause: index, distance: abs(boundary - time))
    }

    /// Frames at speech level, in the full band and above 4 kHz.
    func speech(_ frames: [Int]) -> (full: Int, high: Int) {
        let inside = frames.filter { $0 >= 0 && $0 < energy.full.count }
        return (inside.filter { energy.full[$0] >= levels.fullSpeech }.count, inside.filter { energy.high[$0] >= levels.highSpeech }.count)
    }

    public func judge(
        at time: Double, keeps side: CutAudit.Side, removed: ClosedRange<Double>? = nil, words: [ClosedRange<Double>] = []
    ) -> CutAudit.Edge {
        let step = Self.step
        let x = (time - energy.start) / step
        let before = Int((x - 1e-6).rounded(.up)) - 1
        let after = Int((x + 1e-6).rounded(.down))
        let (keptFrame, keptStep, lostFrame, lostStep) = side == .before ? (before, -1, after, 1) : (after, 1, before, -1)
        if isPause(keptFrame) || isPause(lostFrame) { return .clean }

        let score = score(at: time, keeps: side)
        let lost = run(from: lostFrame, lostStep, edge: time)
        let kept = run(from: keptFrame, keptStep, edge: time)
        let reachable = { (run: Run) in run.distance <= CutAudit.reach + 1e-9 }
        let lostSpeech = speech(Array(lost.frames.prefix(Int((CutAudit.reach / step).rounded()))))
        let voiced = max(lostSpeech.full, lostSpeech.high) >= Int((CutAudit.minSpeech / step).rounded())
        // The voice past the edge stops at a pause just after it: the rest
        // of the word the clip keeps, not a word of the cut material.
        let runsOn = voiced && reachable(lost)
        let isBurst = runsOn && lost.distance <= CutAudit.burst + 1e-9
        let verdict: CutAudit.Verdict
        if score.margin < CutAudit.clippedUnder || isBurst || (runsOn && score.margin < CutAudit.cleanFrom) {
            verdict = .clipped
        } else {
            verdict = score.margin < CutAudit.cleanFrom ? .marginal : .clean
        }

        var gap: Double?
        for frame in [keptFrame, lostFrame] where isQuiet(frame) {
            var low = frame, high = frame
            while !isPause(low - 1), isQuiet(low - 1) { low -= 1 }
            while !isPause(high + 1), isQuiet(high + 1) { high += 1 }
            gap = Double(high - low + 1) * step
            break
        }
        var edge = CutAudit.Edge(
            verdict: verdict, margin: score.margin, kept: kept.distance, lost: reachable(lost) ? lost.distance : nil,
            gap: gap, highBandOnly: voiced && lostSpeech.full == 0, pause: nil, suggestion: nil, fix: nil
        )
        guard verdict == .clipped else { return edge }

        // On past what's cut off, into a pause in the cut material; or back
        // into a pause in what the clip keeps, dropping a fragment.
        var moves: [(to: Double, pause: ClosedRange<Double>)] = []
        if reachable(lost) {
            let pause = pause(at: lost.pause)
            let to = target(in: pause, direction: lostStep, startOfClip: side == .after)
            let inCut = removed.map { $0.lowerBound - 1e-6 <= to && to <= $0.upperBound + 1e-6 } ?? true
            if inCut, !Self.holdsWord(words, min(time, to)...max(time, to)) { moves.append((to, pause)) }
        }
        if reachable(kept) {
            let pause = pause(at: kept.pause)
            let to = target(in: pause, direction: keptStep, startOfClip: false)
            if !Self.holdsWord(words, min(time, to)...max(time, to)) { moves.append((to, pause)) }
        }
        if let move = moves.first {
            edge.pause = move.pause
            edge.suggestion = move.to
            edge.fix = .trim(to: move.to)
        } else if let removed, removed.upperBound - removed.lowerBound <= CutAudit.putBackLimit + 1e-6 {
            edge.fix = .putBack
        } else {
            edge.fix = .nothingNearby
        }
        return edge
    }

    /// Where in `pause` an edge moving `direction` goes: `pad` into it, so
    /// the sound it moved past isn't right on the cut. The start of a clip
    /// moving back into the pause before its word goes `lead` before the
    /// word instead, as near as a frame to the far side of a short pause:
    /// what's there is cut material, so it costs nothing to be near it.
    func target(in pause: ClosedRange<Double>, direction: Int, startOfClip: Bool) -> Double {
        let length = pause.upperBound - pause.lowerBound
        if startOfClip, direction < 0 {
            return max(pause.upperBound - CutAudit.lead, pause.lowerBound + min(Self.step, length / 2))
        }
        let pad = min(CutAudit.pad, length / 2)
        return direction > 0 ? pause.lowerBound + pad : pause.upperBound - pad
    }

    /// Whether a transcript word is in `stretch`. Its times can be 30 to
    /// 100 ms off the sound, so a word reaching a little way in doesn't
    /// count; more than `wordTolerance` of it (or half a shorter one) does,
    /// rather than risk it.
    static func holdsWord(_ words: [ClosedRange<Double>], _ stretch: ClosedRange<Double>) -> Bool {
        words.contains { word in
            let overlap = min(word.upperBound, stretch.upperBound) - max(word.lowerBound, stretch.lowerBound)
            return overlap > min(CutAudit.wordTolerance, (word.upperBound - word.lowerBound) / 2)
        }
    }
}
