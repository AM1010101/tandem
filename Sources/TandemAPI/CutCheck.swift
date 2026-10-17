import Foundation
import TandemCore
import TandemMedia

/// `tandem check --cuts`: does a cut on the speech tracks clip a word?
///
/// Transcript word edges can be half a second out and a final "s" barely
/// registers below 4 kHz, so cuts placed from the transcript (or snapped to
/// the quietest point near a word's end) clipped words Mike then heard in
/// review: "takes" cut to "ta", "example", "They're". This reads each
/// file's own sound either side of every edit (no render, so it's quick),
/// judges it with `CutAudit`, and gives the trim that moves each clipped
/// edge into the nearest real pause.
enum CutCheck {
    /// Sound read either side of each edge: room to find a pause, and
    /// enough of the take around it for its noise floor and speech level.
    static let window = 2.0
    static let label = "Move clipped cuts into pauses"

    /// One edge of a speech clip where the take is cut: two clips of it
    /// meeting (not a through-edit), or a clip beside a gap.
    struct Edge: Sendable {
        var clip: Clip
        var edge: ClipEdge
        /// The other clip at the cut, if one meets it there.
        var other: String?
        var media: MediaItem

        var time: Time { edge == .end ? clip.end : clip.start }
        var mediaTime: Double { (edge == .end ? clip.sourceEnd : clip.sourceStart).seconds }
    }

    struct Outcome: Sendable {
        var problems: [CheckProblem] = []
        /// The fixes, latest first (an incoming clip before the outgoing
        /// one at the same cut), so each trim's times are still right
        /// when it runs.
        var commands: [EditCommand] = []
        var checked = 0
        var warnings: [String] = []
    }

    /// The edges on the speech tracks with their cut in `ranges`.
    static func edges(in project: Project, ranges: [TimeRange]) -> [Edge] {
        let tolerance = project.settings.frameRate.flicksPerFrame / 2
        func touching(_ a: Time, _ b: Time) -> Bool { abs((a - b).flicks) <= tolerance }
        func throughEdit(_ a: Clip, _ b: Clip) -> Bool {
            a.mediaID == b.mediaID && a.speed == b.speed && touching(b.sourceStart, a.sourceEnd)
        }
        func checked(_ time: Time) -> Bool { ranges.contains { $0.start <= time && time <= $0.end } }
        var edges: [Edge] = []
        for track in TranscriptTools.speechTracks(project) {
            let clips = track.clips.filter { clip in
                guard TranscriptTools.isHeard(clip), let id = clip.mediaID, let item = project.media(id) else { return false }
                return item.hasAudio && item.role != .sfx && item.role != .music
            }.sorted { $0.start < $1.start }
            for (index, clip) in clips.enumerated() {
                guard let media = clip.mediaID.flatMap(project.media) else { continue }
                let previous = index > 0 && touching(clips[index - 1].end, clip.start) ? clips[index - 1] : nil
                let next = index + 1 < clips.count && touching(clips[index + 1].start, clip.end) ? clips[index + 1] : nil
                if previous.map({ !throughEdit($0, clip) }) ?? true, checked(clip.start) {
                    edges.append(Edge(clip: clip, edge: .start, other: previous?.id, media: media))
                }
                if next.map({ !throughEdit(clip, $0) }) ?? true, checked(clip.end) {
                    edges.append(Edge(clip: clip, edge: .end, other: next?.id, media: media))
                }
            }
        }
        return edges
    }

    static func run(project: Project, folder: ProjectFolder, ranges: [TimeRange]) async -> Outcome {
        let edges = edges(in: project, ranges: ranges)
        var outcome = Outcome(checked: edges.count)
        var found: [(edge: Edge, problem: CheckProblem)] = []
        let byMedia = Dictionary(grouping: edges, by: \.media.id)
        for mediaID in byMedia.keys.sorted() {
            guard let group = byMedia[mediaID], let item = group.first?.media else { continue }
            // One read for each stretch of the file the edges' windows cover.
            var windows: [ClosedRange<Double>] = []
            for time in group.map(\.mediaTime).sorted() {
                let window = (time - window)...(time + window)
                if let last = windows.last, window.lowerBound <= last.upperBound {
                    windows[windows.count - 1] = last.lowerBound...window.upperBound
                } else {
                    windows.append(window)
                }
            }
            var readings: [SpeechEnergy] = []
            do {
                for window in windows {
                    readings.append(try await SpeechEnergy.read(url: folder.url(for: item), from: window.lowerBound, to: window.upperBound))
                }
            } catch {
                outcome.warnings.append("Couldn't read the sound of \(URL(fileURLWithPath: item.path).lastPathComponent), so its cuts weren't checked.")
                continue
            }
            let levels = SpeechLevels(of: readings)
            // A screen recording's system sound, say: nothing said to clip.
            guard levels.isVoice else { continue }
            for edge in group {
                guard let energy = readings.first(where: { $0.start <= edge.mediaTime && edge.mediaTime <= $0.end }) else { continue }
                let verdict = CutAudit.judge(energy, levels: levels, at: edge.mediaTime, keeps: edge.edge == .end ? .before : .after)
                guard verdict.clipped else { continue }
                found.append((edge, problem(edge, verdict, project: project)))
            }
        }
        found.sort { ($0.edge.time, $0.edge.edge == .end ? 0 : 1) < ($1.edge.time, $1.edge.edge == .end ? 0 : 1) }
        outcome.problems = found.map(\.problem)
        outcome.commands = found.reversed().compactMap(\.problem.cut?.fix)
        return outcome
    }

    /// The problem for a clipped edge, with the trim into the pause when
    /// there's one to reach.
    static func problem(_ edge: Edge, _ verdict: CutAudit.Edge, project: Project) -> CheckProblem {
        let clip = edge.clip
        let isEnd = edge.edge == .end
        let place = isEnd ? "at the end of \(clip.id)" : "at the start of \(clip.id)"
        var what: String
        if let lost = verdict.lost {
            what = isEnd
                ? "the voice runs on \(String(format: "%.2f", lost)) s past the cut"
                : "the voice starts \(String(format: "%.2f", lost)) s before the cut"
        } else {
            what = isEnd
                ? "the voice runs on past the cut with no pause within \(String(format: "%.1f", CutAudit.reach)) s"
                : "the voice was already going \(String(format: "%.1f", CutAudit.reach)) s before the cut"
        }
        if verdict.highBandOnly { what += ", heard only above 4 kHz (an \"s\" or a \"t\")" }
        if let gap = verdict.gap {
            what += "; the cut is in a \(String(format: "%.2f", gap)) s gap inside a word, not a pause"
        }

        var cut = CheckProblem.CutEdge(clipID: clip.id, edge: edge.edge)
        var advice = "No pause within \(String(format: "%.1f", CutAudit.reach)) s either side: listen with tandem clip and recut it by hand."
        if let delta = shift(edge, verdict, project: project) {
            let to = edge.time + delta
            cut.to = to
            cut.fix = .trim(clipID: clip.id, edge: edge.edge, to: to, ripple: true, includeLinked: nil)
            let later = delta > .zero
            let amount = String(format: "%.3f", abs(delta.seconds))
            let into: String
            switch (isEnd, later) {
            case (true, true): into = "into the pause after it."
            case (true, false): into = "into the pause before it, dropping the start of the word."
            case (false, false): into = "into the pause before it."
            case (false, true): into = "into the pause after it, dropping the end of the word."
            }
            advice = "Trim the \(isEnd ? "end" : "start") \(amount) s \(later ? "later" : "earlier"), \(into)"
        }
        return CheckProblem(
            kind: .clippedWord, start: edge.time, end: edge.time,
            message: "Clipped word \(place): \(what). \(advice)",
            clipIDs: isEnd ? [clip.id] + (edge.other.map { [$0] } ?? []) : (edge.other.map { [$0] } ?? []) + [clip.id],
            cut: cut
        )
    }

    /// How far to move the edge on the timeline to reach the suggested
    /// pause, in whole frames when one lands in the pause (as `tighten`'s
    /// cuts do), so the rest of the take stays on frames. Nil when there's
    /// no pause to reach, or the clip can't move there (past its file, or
    /// trimmed to nothing).
    static func shift(_ edge: Edge, _ verdict: CutAudit.Edge, project: Project) -> Time? {
        guard let target = verdict.suggestion, let pause = verdict.pause else { return nil }
        let clip = edge.clip
        let rate = project.settings.frameRate
        let ideal = (target - edge.mediaTime) / clip.speed
        let frame = rate.frameDuration.seconds
        let snapped = [(ideal / frame).rounded(.down), (ideal / frame).rounded(.up)]
            .filter { pause.contains(edge.mediaTime + $0 * frame * clip.speed) }
            .min { abs($0 * frame - ideal) < abs($1 * frame - ideal) }
        let delta = snapped.map { Time.frames(Int64($0), at: rate) } ?? Time(seconds: ideal)
        guard delta != .zero else { return nil }
        let moved = delta.seconds * clip.speed
        let duration = clip.duration.seconds + (edge.edge == .end ? delta.seconds : -delta.seconds)
        guard duration >= frame else { return nil }
        if !clip.holdEdges {
            if edge.edge == .start, clip.sourceStart.seconds + moved < 0 { return nil }
            if edge.edge == .end, let length = edge.media.duration, clip.sourceEnd.seconds + moved > length.seconds + frame { return nil }
        }
        return delta
    }
}
