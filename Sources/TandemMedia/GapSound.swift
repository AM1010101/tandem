import Foundation

/// One track's sound as it plays on the timeline: the clips on it, each
/// with its file's sound (`CutPlacer`) and where it plays from.
///
/// Times here are seconds on the timeline, so the sound of every track can
/// be laid over the others: a pause is only a pause when it's quiet on all
/// of them (#11).
public struct SoundLayer: Sendable {
    public struct Piece: Sendable {
        /// Where the clip plays on the timeline.
        public var timeline: Range<Double>
        /// The file's media time at `timeline.lowerBound`.
        public var mediaStart: Double
        public var speed: Double
        public var placer: CutPlacer

        public init(timeline: Range<Double>, mediaStart: Double, speed: Double, placer: CutPlacer) {
            self.timeline = timeline
            self.mediaStart = mediaStart
            self.speed = speed
            self.placer = placer
        }

        public func media(_ time: Double) -> Double { mediaStart + (time - timeline.lowerBound) * speed }
    }

    /// The track's name, to say where a sound is.
    public var name: String
    public var pieces: [Piece]

    public init(name: String, pieces: [Piece]) {
        self.name = name
        self.pieces = pieces
    }

    /// The piece playing at `time`, or (`ending`) the one playing up to it.
    func piece(at time: Double, ending: Bool = false) -> Piece? {
        pieces.first { ending ? ($0.timeline.lowerBound < time && time <= $0.timeline.upperBound) : $0.timeline.contains(time) }
    }
}

/// What the sound under a gap between two transcript words has in it, and
/// where tighten's cut goes there.
///
/// The transcript only says roughly where the gap is. Its word times are
/// 30 to 200 ms off the sound (#64), and its word edges come from where the
/// waveform is over one floor for the whole take, so a quiet second
/// speaker, an app talking, or a breath reads as silence (#11). So the gap
/// is measured from the sound, on every track that plays there: from the
/// end of the last word's sound to the start of the next word's. Sound is
/// measured as `CutPlacer` measures it, in 5 ms frames against each file's
/// own floor (the quietest tenth of 3 s either side), and a real pause is
/// 80 ms or more with no sound on any track (`fullOverFloor`,
/// `highOverFloor`).
///
/// Sound in the gap that isn't either word (an island no transcript word
/// calls home) is `heard`: the cut never goes through it, only in the quiet
/// beside it. Then the join is judged by `CutPlacer.judge`, exactly as
/// `tandem check --cuts` will judge it.
public struct GapSound: Equatable, Sendable {
    /// Sound in the gap the transcript has no word for, in timeline time,
    /// with the tracks it's heard on.
    public struct Heard: Equatable, Sendable {
        public var range: ClosedRange<Double>
        public var layers: [String]
    }

    /// From the end of the last word's sound to the start of the next
    /// word's, in timeline time. The transcript's gap when the sound runs
    /// right through it.
    public var span: ClosedRange<Double>
    /// The real pauses in `span`: quiet on every track.
    public var pauses: [ClosedRange<Double>]
    public var heard: [Heard]
    /// The two words' sound runs together with no real pause between them:
    /// the transcript has a gap in running speech, or speech too quiet for
    /// its word edges.
    public var runsThrough: Bool

    /// The least of a pause kept beside a cut in it, either side: the Ian
    /// video's fixes put edges 30 ms inside a real pause (#64, measured),
    /// so a soft tail or the start of the next sound isn't on the cut.
    public static var edgeGuard: Double { CutAudit.pad }
    /// How far past the transcript's gap the words' sound can be.
    static var slack: Double { CutPlanner.slack }
    /// A frame is sound when it's this many dB over its file's local floor
    /// in the full band: `CutAudit.overFloor` and 3 more, since 5 ms frames
    /// of a room's rumble reach a dB or two over floor + 9 every so often,
    /// and a voice 20 dB under the speaker is 5 to 10 over it (a guess
    /// between the two, on synthetic rumble).
    static let fullOverFloor: Float = CutAudit.overFloor + 3
    /// And this many over it above 4 kHz, not `CutAudit.highOverFloor`'s
    /// 20: a breath sits 10 to 20 dB over the floor there, and
    /// `check --cuts` lets a join's edge sit in one, but a breath cut in
    /// half is something Mike hears. So in a gap a breath is sound, and
    /// tighten cuts beside it. Hiss above 4 kHz is steady, so it needs no
    /// margin over the 9 dB the full band's quiet line has.
    static let highOverFloor: Float = CutAudit.overFloor
    /// Sound reaches out through frames up to this far under those lines
    /// that touch it: a word's soft tail is the word's.
    static let tailUnder: Float = 3

    // MARK: - Listening

    /// The sound under `gap`, between transcript words `before` and
    /// `after` (all timeline time), on `layers`. Nil when some of the gap
    /// isn't played by any of them, so nobody knows what's there.
    public static func listen(
        gap: ClosedRange<Double>, before: ClosedRange<Double>, after: ClosedRange<Double>, layers: [SoundLayer]
    ) -> GapSound? {
        let step = SpeechEnergy.frameSeconds
        // Room for the words' own sound either side, which the transcript
        // can have up to `slack` out.
        let low = min(before.lowerBound - 0.1, gap.lowerBound - slack)
        let high = max(after.upperBound + 0.1, gap.upperBound + slack)
        let count = Int(((high - low) / step).rounded(.up))
        guard count > 0 else { return nil }
        func time(_ index: Int) -> Double { low + Double(index) * step }

        // How far over the line for sound each track is, against its own
        // floor where it's played (`around` either side, taken once a
        // second of its file): the louder of the full band and above 4 kHz.
        var arounds: [String: CutPlacer.Around] = [:]
        func over(_ layer: Int, at t: Double) -> Float? {
            guard let pieceIndex = layers[layer].pieces.firstIndex(where: { $0.timeline.contains(t) }) else { return nil }
            let piece = layers[layer].pieces[pieceIndex]
            let media = piece.media(t)
            let chunk = Int(media.rounded(.down))
            let key = "\(layer)/\(pieceIndex)/\(chunk)"
            let near = arounds[key] ?? piece.placer.around(Double(chunk) + 0.5)
            arounds[key] = near
            let energy = piece.placer.energy
            let frame = energy.index(of: media)
            // Past the file's ends is silence.
            guard frame >= 0, frame < energy.full.count else { return -120 }
            return max(energy.full[frame] - (near.floor + fullOverFloor), energy.high[frame] - (near.highFloor + highOverFloor))
        }

        // The loudest track's excess at each frame, and which tracks have
        // sound there.
        var excess = [Float](repeating: -120, count: count)
        var sounding = [[Bool]](repeating: [Bool](repeating: false, count: count), count: layers.count)
        for index in 0..<count {
            let t = time(index) + step / 2
            var heardBy = 0
            for layer in layers.indices {
                guard let level = over(layer, at: t) else { continue }
                heardBy += 1
                excess[index] = max(excess[index], level)
                if level >= 0 { sounding[layer][index] = true }
            }
            if heardBy == 0 {
                // Unplayed: inside the gap nothing can be said about it, and
                // beside it it's no pause to cut in.
                if gap.lowerBound < t && t < gap.upperBound { return nil }
                excess[index] = .infinity
            }
        }

        // Islands of sound: frames of it with less than a real pause
        // (`CutAudit.minPause`) between them. A group with less than
        // `CutPlanner.soundFrames` of them is a blip of room noise in a
        // pause. Each island reaches out from its sound through the frames
        // within `tailUnder` of the line touching it, a word's soft tail,
        // but not to a blip across the quiet.
        let pauseLength = Int((CutAudit.minPause / step).rounded())
        let loudFrames = (0..<count).filter { excess[$0] >= 0 }
        var groups: [[Int]] = []
        for frame in loudFrames {
            if let last = groups.last?.last, frame - last <= pauseLength { groups[groups.count - 1].append(frame) } else { groups.append([frame]) }
        }
        var islands: [Range<Int>] = []
        for group in groups where group.count >= CutPlanner.soundFrames {
            var low = group.first!, high = group.last! + 1
            func touching(_ frame: Int) -> Bool { frame >= 0 && frame < count && excess[frame] >= -tailUnder }
            while touching(low - 1) || touching(low - 2) { low -= touching(low - 1) ? 1 : 2 }
            while touching(high) || touching(high + 1) { high += touching(high) ? 1 : 2 }
            if let last = islands.last, low <= last.upperBound {
                islands[islands.count - 1] = last.lowerBound..<max(last.upperBound, high)
            } else {
                islands.append(low..<high)
            }
        }
        func span(_ island: Range<Int>) -> ClosedRange<Double> { time(island.lowerBound)...time(island.upperBound) }
        func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
            max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        }
        func heardOn(_ island: Range<Int>) -> [String] {
            layers.indices.filter { layer in island.contains { sounding[layer][$0] } }.map { layers[$0].name }
        }
        // Each word's home: the island holding most of it, so a word the
        // transcript has 0.2 s out still lands in the right one.
        func home(_ word: ClosedRange<Double>) -> Int? {
            let best = islands.indices.max { overlap(span(islands[$0]), word) < overlap(span(islands[$1]), word) }
            return best.flatMap { overlap(span(islands[$0]), word) > 0 ? $0 : nil }
        }
        let last = home(before), next = home(after)
        let from = last.map { span(islands[$0]).upperBound } ?? before.upperBound
        let to = next.map { span(islands[$0]).lowerBound } ?? after.lowerBound
        if let last, let next, last >= next {
            let through = islands[last]
            let range = max(gap.lowerBound, span(through).lowerBound)...min(gap.upperBound, span(through).upperBound)
            return GapSound(span: gap, pauses: [], heard: [Heard(range: range, layers: heardOn(through))], runsThrough: true)
        }
        guard to > from else {
            return GapSound(span: gap, pauses: [], heard: [], runsThrough: true)
        }

        // Sound between the two words' own is heard: never cut through.
        var heard: [Heard] = []
        for (number, island) in islands.enumerated() where number != last && number != next {
            let range = span(island)
            guard range.upperBound > from, range.lowerBound < to else { continue }
            heard.append(Heard(range: max(from, range.lowerBound)...min(to, range.upperBound), layers: heardOn(island)))
        }
        var pauses: [ClosedRange<Double>] = []
        var start = from
        for sound in heard {
            if sound.range.lowerBound > start { pauses.append(start...sound.range.lowerBound) }
            start = max(start, sound.range.upperBound)
        }
        if to > start { pauses.append(start...to) }
        return GapSound(span: from...to, pauses: pauses, heard: heard, runsThrough: false)
    }

    // MARK: - Placing the cut

    /// Why a gap isn't cut.
    public enum Refusal: String, Error, Codable, Sendable {
        /// The voice runs right through it: no real pause.
        case speech
        /// Sound the transcript doesn't know about leaves no pause long
        /// enough to cut in.
        case sound
        /// Measured from the sound, the gap is shorter than the minimum.
        case short
        /// It's already no longer than the keep: nothing to cut.
        case fits
    }

    public struct Placement: Equatable, Sendable {
        /// The real pause the cut is in.
        public var pause: ClosedRange<Double>
        /// The cut, before it's put on frames: the keep split either side.
        public var from: Double
        public var to: Double
        /// As far as an edge may go towards the pause's ends when it's put
        /// on a frame: `edgeGuard` inside.
        public var earliest: Double
        public var latest: Double
        /// The pause the cut leaves in `pause`.
        public var inside: Double
    }

    /// Where the cut goes to leave `keep` between the two words' sound,
    /// when the gap is at least `minimum`: in the longest real pause, with
    /// the keep split evenly either side of it (`edgeGuard` at least each
    /// side). Sound in the gap and the other pauses beside it stay as they
    /// are and count towards the keep: one cut per gap, as tighten always
    /// made, so there's no more joins than before. It needs room for at
    /// least a `frame`.
    public func place(keep: Double, minimum: Double, frame: Double) -> Result<Placement, Refusal> {
        if runsThrough { return .failure(.speech) }
        func length(_ range: ClosedRange<Double>) -> Double { range.upperBound - range.lowerBound }
        guard length(span) >= minimum - 1e-9 else { return .failure(.short) }
        guard let pause = pauses.max(by: { length($0) < length($1) }) else { return .failure(.sound) }
        let others = length(span) - length(pause)
        let inside = max(0, keep - others)
        let tail = max(Self.edgeGuard, inside / 2)
        let lead = max(Self.edgeGuard, inside - inside / 2)
        guard length(pause) - tail - lead >= frame - 1e-9 else {
            if !heard.isEmpty { return .failure(.sound) }
            return .failure(length(span) <= keep + frame ? .fits : .short)
        }
        return .success(Placement(
            pause: pause, from: pause.lowerBound + tail, to: pause.upperBound - lead,
            earliest: pause.lowerBound + Self.edgeGuard, latest: pause.upperBound - Self.edgeGuard, inside: tail + lead
        ))
    }

    // MARK: - Judging the join

    /// How one side of a join sounds, the worst of the tracks that carry a
    /// voice there, as `tandem check --cuts` judges each.
    public struct Join: Equatable, Sendable {
        public var verdict: CutAudit.Verdict
        /// How far the clip's 25 ms beside the edge is under the speech, dB,
        /// on the track it's worst on. Nil when no track has a voice.
        public var margin: Float?
        public var layer: String?

        static let silent = Join(verdict: .clean, margin: nil, layer: nil)
    }

    /// Both sides of the join a cut from `from` to `to` (timeline) leaves,
    /// judged on every layer playing there that carries a voice. A track
    /// with no voice (a device's recording that's digital silence) has
    /// nothing to clip; its quiet already counted in the pause.
    public static func judge(_ layers: [SoundLayer], from: Double, to: Double) -> (start: Join, end: Join) {
        var start = Join.silent, end = Join.silent
        func worse(_ a: Join, than b: Join) -> Bool {
            let rank: [CutAudit.Verdict: Int] = [.clean: 0, .marginal: 1, .clipped: 2]
            if rank[a.verdict]! != rank[b.verdict]! { return rank[a.verdict]! > rank[b.verdict]! }
            return (a.margin ?? .infinity) < (b.margin ?? .infinity)
        }
        for layer in layers {
            let before = layer.piece(at: from, ending: true), after = layer.piece(at: to)
            // What's cut out between them, when one piece of the file plays
            // both sides: a fix there would only reach into it.
            var removed: ClosedRange<Double>?
            if let before, let after, before.timeline == after.timeline, before.media(from) <= after.media(to) {
                removed = before.media(from)...after.media(to)
            }
            if let before, before.placer.levels.isVoice {
                let time = before.media(from)
                let edge = before.placer.judge(at: time, keeps: .before, removed: removed)
                let join = Join(verdict: edge.verdict, margin: before.placer.score(at: time, keeps: .before).margin, layer: layer.name)
                if worse(join, than: start) { start = join }
            }
            if let after, after.placer.levels.isVoice {
                let time = after.media(to)
                let edge = after.placer.judge(at: time, keeps: .after, removed: removed)
                let join = Join(verdict: edge.verdict, margin: after.placer.score(at: time, keeps: .after).margin, layer: layer.name)
                if worse(join, than: end) { end = join }
            }
        }
        return (start, end)
    }
}
