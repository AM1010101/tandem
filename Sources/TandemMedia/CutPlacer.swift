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

    private static let step = SpeechEnergy.frameSeconds

    public init(_ energy: SpeechEnergy, levels: SpeechLevels) {
        self.energy = energy
        self.levels = levels
    }

    /// What's quiet and what's speech around one edge, from the sound
    /// `CutAudit.around` either side of it, and the real pauses there.
    ///
    /// The floor is local because a take's loudness drifts: on the Ian
    /// video (#64) a floor and a loud cap for the whole take let soft
    /// syllables inside words count as pauses, and the pause search that
    /// worked there took its floor from the few seconds by the join.
    public struct Around: Sendable {
        /// The quietest tenth, full band and above 4 kHz, dB.
        public var floor: Float
        public var highFloor: Float
        /// Quiet is under these.
        public var quiet: Float
        public var highQuiet: Float
        /// The speech level: the loud end of the sound here, dB.
        public var speech: Float
        /// The frames these cover, and which of them are quiet and in a
        /// real pause.
        let frames: Range<Int>
        let quietFrames: [Bool]
        let pauseFrames: [Bool]
        /// Quiet gaps shorter than a pause with a transcript word boundary
        /// by them (`CutPlacer.betweenWords`): none without a transcript.
        var wordGapFrames: [Bool] = []
        /// How many frames were read.
        let count: Int

        /// Before the first frame read or after the last is the file's
        /// start or end (reads reach well past every edge otherwise), so
        /// it's a pause. Past the stretch looked at is never reached.
        func isPause(_ index: Int) -> Bool {
            if index < 0 || index >= count { return true }
            return frames.contains(index) && pauseFrames[index - frames.lowerBound]
        }

        func isWordGap(_ index: Int) -> Bool {
            frames.contains(index) && !wordGapFrames.isEmpty && wordGapFrames[index - frames.lowerBound]
        }

        /// A real pause or a gap between words: where a word has ended.
        func isStop(_ index: Int) -> Bool { isPause(index) || isWordGap(index) }

        func isQuiet(_ index: Int) -> Bool {
            if index < 0 || index >= count { return true }
            return frames.contains(index) && quietFrames[index - frames.lowerBound]
        }
    }

    public func around(_ time: Double) -> Around {
        let count = energy.full.count
        let span = Int((CutAudit.around / Self.step).rounded())
        let centre = energy.index(of: time)
        let frames = max(0, min(count, centre - span))..<max(0, min(count, centre + span))
        func percentile(_ values: ArraySlice<Float>, _ p: Double) -> Float {
            let sorted = values.sorted()
            return sorted.isEmpty ? -120 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let floor = percentile(energy.full[frames], CutAudit.floorPercentile)
        let highFloor = percentile(energy.high[frames], CutAudit.floorPercentile)
        let quiet = floor + CutAudit.overFloor
        let highQuiet = highFloor + CutAudit.highOverFloor
        let quietFrames = frames.map { energy.full[$0] < quiet && energy.high[$0] < highQuiet }

        // Quiet runs long enough to be pauses, and runs reaching the start
        // or end of the frames read: that's the file's start or end.
        let pauseLength = Int((CutAudit.minPause / Self.step).rounded())
        var pauseFrames = [Bool](repeating: false, count: quietFrames.count)
        var runStart = 0
        for index in 0...quietFrames.count where index == quietFrames.count || !quietFrames[index] {
            let atFileEdge = (runStart == 0 && frames.lowerBound == 0) || (index == quietFrames.count && frames.upperBound == count)
            if index > runStart, index - runStart >= pauseLength || atFileEdge {
                for k in runStart..<index { pauseFrames[k] = true }
            }
            runStart = index + 1
        }
        return Around(
            floor: floor, highFloor: highFloor, quiet: quiet, highQuiet: highQuiet,
            speech: percentile(energy.full[frames], CutAudit.speechPercentile),
            frames: frames, quietFrames: quietFrames, pauseFrames: pauseFrames, count: count
        )
    }

    /// The pause (or gap between words) holding frame `index`, in media time.
    func pause(at index: Int, in near: Around) -> ClosedRange<Double> {
        let count = energy.full.count
        // Past the frames read: the file's start or end, of no known length,
        // so it's given room for the pad.
        if index < 0 { return (energy.start - 1)...energy.start }
        if index >= count { return energy.end...(energy.end + 1) }
        var low = index, high = index
        while low - 1 >= 0, near.isStop(low - 1) { low -= 1 }
        while high + 1 < count, near.isStop(high + 1) { high += 1 }
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
        score(at: time, keeps: side, speech: around(time).speech)
    }

    func score(at time: Double, keeps side: CutAudit.Side, speech: Float) -> JoinScore {
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
        return JoinScore(keptDB: kept, speechDB: speech)
    }

    /// The frames from one beside an edge, going away from it, up to the
    /// first frame of a pause or a gap between words, or `reach` and no
    /// further.
    struct Run {
        var frames: [Int]
        var pause: Int
        /// Seconds from the edge to the pause, when it's within `reach`.
        var distance: Double?
    }

    func run(from frame: Int, _ direction: Int, edge time: Double, in near: Around) -> Run {
        var frames: [Int] = []
        var index = frame
        let limit = Int((CutAudit.reach / Self.step).rounded()) + 1
        while !near.isStop(index), frames.count <= limit {
            frames.append(index)
            index += direction
        }
        let boundary = energy.start + Double(direction > 0 ? index : index + 1) * Self.step
        let distance = abs(boundary - time)
        return Run(frames: frames, pause: index, distance: near.isStop(index) && distance <= CutAudit.reach + 1e-9 ? distance : nil)
    }

    /// Frames at speech level, in the full band and above 4 kHz. Never
    /// quiet, either: in a take with next to nothing above 4 kHz, its loud
    /// tenth there is room noise.
    func speech(_ frames: [Int], in near: Around) -> (full: Int, high: Int) {
        let inside = frames.filter { $0 >= 0 && $0 < energy.full.count }
        let full = max(near.quiet, near.speech - CutAudit.runOnUnder)
        let high = max(near.highQuiet, levels.highSpeech)
        return (inside.filter { energy.full[$0] >= full }.count, inside.filter { energy.high[$0] >= high }.count)
    }

    /// - Parameter words: transcript words around the edge, with no text.
    public func judge(
        at time: Double, keeps side: CutAudit.Side, removed: ClosedRange<Double>? = nil, words: [ClosedRange<Double>] = []
    ) -> CutAudit.Edge {
        judge(at: time, keeps: side, removed: removed, transcript: words.map { CutAudit.Word(text: "", start: $0.lowerBound, end: $0.upperBound) })
    }

    /// How an edge sounds, and the fix when it's clipped.
    ///
    /// With no transcript, it's the sound alone: a quiet gap shorter than a
    /// pause can't be told from the closure inside a word, so it's judged
    /// as one. With one, a quiet gap of `minWordGap` or more by a word
    /// boundary (`betweenWords`) is a gap between words. An edge in it is
    /// clean, whatever the next word does 40 ms on, and voice past an edge
    /// only clips it up to such a gap: past it is the next word's voice,
    /// which the cut is meant to take. Of the 25 joins Mike approved on the
    /// Ian video's final cut that the sound alone flagged, that cleared 16.
    ///
    /// - Parameters:
    ///   - removed: at a cut between two pieces of one take, the stretch of
    ///     the file cut out between them; a fix only reaches into it.
    ///   - transcript: the words around the edge, in media time. Their times
    ///     only say where a word boundary can be; the sound says where it
    ///     is. They also keep a fix from bringing a cut word back or
    ///     dropping a kept one.
    public func judge(
        at time: Double, keeps side: CutAudit.Side, removed: ClosedRange<Double>? = nil, transcript: [CutAudit.Word]
    ) -> CutAudit.Edge {
        let step = Self.step
        let x = (time - energy.start) / step
        let before = Int((x - 1e-6).rounded(.up)) - 1
        let after = Int((x + 1e-6).rounded(.down))
        let (keptFrame, keptStep, lostFrame, lostStep) = side == .before ? (before, -1, after, 1) : (after, 1, before, -1)
        var near = around(time)
        if near.isPause(keptFrame) || near.isPause(lostFrame) { return .clean }
        near.wordGapFrames = betweenWords(transcript, in: near)
        let lastWord = side == .before ? CutAudit.lastWordCut(transcript, at: time, removed: removed) : nil
        if lastWord == nil, near.isWordGap(keptFrame) || near.isWordGap(lostFrame) {
            var edge = CutAudit.Edge.clean
            edge.betweenWords = true
            return edge
        }

        let score = score(at: time, keeps: side, speech: near.speech)
        // Past the sentence's last word, from the edge's own gap if it's in
        // one, is where a fix that finishes it goes.
        var lostFrom = lostFrame
        if lastWord != nil {
            while near.isWordGap(lostFrom), abs(lostFrom - lostFrame) < Int((CutAudit.reach / step).rounded()) { lostFrom += lostStep }
        }
        let lost = run(from: lostFrom, lostStep, edge: time, in: near)
        let kept = run(from: keptFrame, keptStep, edge: time, in: near)
        let lostSpeech = speech(Array(lost.frames.prefix(Int((CutAudit.reach / step).rounded()))), in: near)
        // Voice at speech level past the edge, before any real pause (or,
        // with a transcript, gap between words): the edge is inside a word,
        // or in fluent speech, whatever the clip's side sounds like. On the
        // Ian video most of the cuts the level passed were in a quiet gap
        // inside a word (the closure in "extract", "because", "index"),
        // where the clip's last 25 ms reads 15 to 24 dB under the speech.
        let runsOn = max(lostSpeech.full, lostSpeech.high) >= Int((CutAudit.minSpeech / step).rounded())
        let verdict: CutAudit.Verdict
        if score.margin < CutAudit.clippedUnder || runsOn || lastWord != nil {
            verdict = .clipped
        } else {
            verdict = score.margin < CutAudit.cleanFrom ? .marginal : .clean
        }

        var gap: Double?
        for frame in [keptFrame, lostFrame] where near.isQuiet(frame) {
            var low = frame, high = frame
            while !near.isPause(low - 1), near.isQuiet(low - 1) { low -= 1 }
            while !near.isPause(high + 1), near.isQuiet(high + 1) { high += 1 }
            gap = Double(high - low + 1) * step
            break
        }
        var edge = CutAudit.Edge(
            verdict: verdict, margin: score.margin, kept: kept.distance ?? Double(kept.frames.count) * step, lost: lost.distance,
            gap: gap, highBandOnly: runsOn && lostSpeech.full == 0, pause: nil, suggestion: nil, fix: nil
        )
        edge.lastWordCut = lastWord?.text
        guard verdict == .clipped else { return edge }

        // On past what's cut off, into a pause (or gap between words) in the
        // cut material, finishing the word the edge is in but bringing no
        // other cut word back; or back into one in what the clip keeps,
        // dropping no kept word. A word the edge is inside counts as kept
        // when more than a sliver of it is (`holdsWord`): it's what the clip
        // was cut in, and trimming back over it deletes it ("time" before
        // "And" on the Ian video, #64).
        let cutIn = transcript.filter { $0.start + 1e-6 < time && time < $0.end - 1e-6 } + (lastWord.map { [$0] } ?? [])
        var moves: [(to: Double, pause: ClosedRange<Double>, betweenWords: Bool)] = []
        var drops: String?
        if lost.distance != nil {
            let pause = pause(at: lost.pause, in: near)
            let isPause = near.isPause(lost.pause)
            let to = target(in: pause, direction: lostStep, startOfClip: side == .after, inPause: isPause)
            let inCut = removed.map { $0.lowerBound - 1e-6 <= to && to <= $0.upperBound + 1e-6 } ?? true
            let others = transcript.filter { !cutIn.contains($0) }.map(\.range)
            if inCut, !Self.holdsWord(others, min(time, to)...max(time, to)) { moves.append((to, pause, !isPause)) }
        }
        if kept.distance != nil {
            let pause = pause(at: kept.pause, in: near)
            let isPause = near.isPause(kept.pause)
            let to = target(in: pause, direction: keptStep, startOfClip: false, inPause: isPause)
            let stretch = min(time, to)...max(time, to)
            if let word = transcript.first(where: { Self.holdsWord([$0.range], stretch) }) {
                drops = word.text.isEmpty ? nil : word.text
            } else {
                moves.append((to, pause, !isPause))
            }
        }
        if let move = moves.first {
            edge.pause = move.pause
            edge.suggestion = move.to
            edge.fix = .trim(to: move.to)
            edge.betweenWords = move.betweenWords
        } else {
            edge.drops = drops
            if let removed, removed.upperBound - removed.lowerBound <= CutAudit.putBackLimit + 1e-6 {
                edge.fix = .putBack
            } else {
                edge.fix = .nothingNearby
            }
        }
        return edge
    }

    /// Frames in a quiet gap of `minWordGap` or more, shorter than a pause,
    /// with a transcript word boundary by it: a gap between words. A quiet
    /// dip with no boundary near it is inside a word (the closure before
    /// the "t" of "extract", the dip in "time" before its "m").
    func betweenWords(_ words: [CutAudit.Word], in near: Around) -> [Bool] {
        var gaps = [Bool](repeating: false, count: near.quietFrames.count)
        let boundaries = CutAudit.boundaries(words)
        guard !boundaries.isEmpty else { return gaps }
        let shortest = Int((CutAudit.minWordGap / Self.step).rounded())
        var index = 0
        while index < gaps.count {
            guard near.quietFrames[index], !near.pauseFrames[index] else {
                index += 1
                continue
            }
            var end = index
            while end < gaps.count, near.quietFrames[end] { end += 1 }
            let from = energy.start + Double(near.frames.lowerBound + index) * Self.step
            let to = energy.start + Double(near.frames.lowerBound + end) * Self.step
            if end - index >= shortest, boundaries.contains(where: { $0.overlaps(from...to) }) {
                for k in index..<end { gaps[k] = true }
            }
            index = end
        }
        return gaps
    }

    /// Where in `pause` an edge moving `direction` goes: `pad` into it, so
    /// the sound it moved past isn't right on the cut. The start of a clip
    /// moving back into the pause before its word goes `lead` before the
    /// word instead, as near as a frame to the far side of a short pause:
    /// what's there is cut material, so it costs nothing to be near it. In
    /// a gap between words, which is shorter than `lead`, it goes `pad`
    /// before the word (or halfway, in a gap under twice that), nearer the
    /// word it keeps.
    func target(in pause: ClosedRange<Double>, direction: Int, startOfClip: Bool, inPause: Bool = true) -> Double {
        let length = pause.upperBound - pause.lowerBound
        if startOfClip, direction < 0, inPause {
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
