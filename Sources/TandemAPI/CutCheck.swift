import Foundation
import TandemCore
import TandemMedia

/// `tandem check --cuts`: does a cut on the speech tracks clip a word?
///
/// Transcript word edges can be half a second out and a final "s" barely
/// registers below 4 kHz, so cuts placed from the transcript (or snapped to
/// the quietest point near a word's end) clipped words Mike then heard in
/// review: "takes" cut to "ta", "example", "They're", and on the Ian video
/// "extract" cut to "extrac" and "pro" off "processed" (#64). This reads
/// each file's own sound either side of every edit (no render, so it's
/// quick), judges it with `CutAudit`, and gives the fix for each clipped
/// edge: a trim into a real pause, or putting a short cut back. It passes
/// `CutAudit` the stretch cut at the join and the transcript's words only
/// so a fix never brings a cut word back.
enum CutCheck {
    /// Sound read either side of each edge: the 3 s the speech level is
    /// taken over, which is room to find a pause too, and enough of the take
    /// around it for its noise floor.
    static let window = CutAudit.speechSpan
    static let label = "Move clipped cuts into pauses"

    /// One edge of a speech clip where the take is cut: two clips of it
    /// meeting (not a through-edit), or a clip beside a gap.
    struct Edge: Sendable {
        var clip: Clip
        var edge: ClipEdge
        /// The other clip at the cut, if one meets it there.
        var other: String?
        var media: MediaItem
        /// Where two pieces of one take meet: the clip before the cut, and
        /// the stretch of the file cut out between them (media time).
        var outgoing: Clip?
        var removed: ClosedRange<Double>?

        var time: Time { edge == .end ? clip.end : clip.start }
        var mediaTime: Double { (edge == .end ? clip.sourceEnd : clip.sourceStart).seconds }
    }

    struct Outcome: Sendable {
        var problems: [CheckProblem] = []
        /// Marginal joins: worth a listen, not wrong.
        var notes: [CheckProblem] = []
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
        /// What's cut out of the take between two clips of it meeting: none
        /// between different files, or where the take jumps back.
        func removed(_ a: Clip, _ b: Clip) -> ClosedRange<Double>? {
            guard a.mediaID == b.mediaID, b.sourceStart > a.sourceEnd else { return nil }
            return a.sourceEnd.seconds...b.sourceStart.seconds
        }
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
                    var edge = Edge(clip: clip, edge: .start, other: previous?.id, media: media)
                    if let previous, let removed = removed(previous, clip) { (edge.outgoing, edge.removed) = (previous, removed) }
                    edges.append(edge)
                }
                if next.map({ !throughEdit(clip, $0) }) ?? true, checked(clip.end) {
                    var edge = Edge(clip: clip, edge: .end, other: next?.id, media: media)
                    if let next, let removed = removed(clip, next) { (edge.outgoing, edge.removed) = (clip, removed) }
                    edges.append(edge)
                }
            }
        }
        return edges
    }

    /// The transcript's words for each file on the speech tracks, in media
    /// time, by media ID.
    static func words(in project: Project, analysis: AnalysisSource) -> [String: [ClosedRange<Double>]] {
        var words: [String: [ClosedRange<Double>]] = [:]
        for id in Set(TranscriptTools.speechTracks(project).flatMap(\.clips).compactMap(\.mediaID)) {
            guard let item = project.media(id), let transcript = analysis.transcript(for: item) else { continue }
            words[id] = transcript.words.filter { $0.end > $0.start }.map { $0.start.seconds...$0.end.seconds }
        }
        return words
    }

    /// - Parameter words: each file's transcript words (media time), by
    ///   media ID, so fixes never bring a cut word back.
    static func run(project: Project, folder: ProjectFolder, ranges: [TimeRange], words: [String: [ClosedRange<Double>]] = [:]) async -> Outcome {
        let edges = edges(in: project, ranges: ranges)
        var outcome = Outcome(checked: edges.count)
        var found: [(edge: Edge, verdict: CutAudit.Edge)] = []
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
            let placers = readings.map { CutPlacer($0, levels: levels) }
            let said = words[mediaID] ?? []
            for edge in group {
                guard let placer = placers.first(where: { $0.energy.start <= edge.mediaTime && edge.mediaTime <= $0.energy.end }) else { continue }
                let near = (edge.mediaTime - window)...(edge.mediaTime + window)
                let verdict = placer.judge(
                    at: edge.mediaTime, keeps: edge.edge == .end ? .before : .after, removed: edge.removed, words: said.filter { $0.overlaps(near) }
                )
                guard verdict.verdict != .clean else { continue }
                found.append((edge, verdict))
            }
        }
        // Where one side of a join is put back, so is the other: it's one
        // trim, and a trim into a pause as well would fight it.
        let puttingBack = Set(found.filter { $0.verdict.fix == .putBack }.compactMap(\.edge.outgoing?.id))
        for index in found.indices where found[index].verdict.clipped {
            if let outgoing = found[index].edge.outgoing, puttingBack.contains(outgoing.id) {
                found[index].verdict.fix = .putBack
                found[index].verdict.suggestion = nil
            }
        }
        found.sort { ($0.edge.time, $0.edge.edge == .end ? 0 : 1) < ($1.edge.time, $1.edge.edge == .end ? 0 : 1) }
        let problems = found.map { problem($0.edge, $0.verdict, project: project) }
        outcome.problems = problems.filter { $0.kind == .clippedWord }
        outcome.notes = problems.filter { $0.kind == .marginalJoin }
        for fix in outcome.problems.reversed().compactMap(\.cut?.fix) where !outcome.commands.contains(fix) {
            outcome.commands.append(fix)
        }
        return outcome
    }

    /// The problem for a clipped edge, with its fix, or the note for a
    /// marginal one.
    static func problem(_ edge: Edge, _ verdict: CutAudit.Edge, project: Project) -> CheckProblem {
        let clip = edge.clip
        let isEnd = edge.edge == .end
        let place = isEnd ? "at the end of \(clip.id)" : "at the start of \(clip.id)"
        let clipIDs = isEnd ? [clip.id] + (edge.other.map { [$0] } ?? []) : (edge.other.map { [$0] } ?? []) + [clip.id]
        let margin = verdict.margin.map { (Double($0) * 10).rounded() / 10 }
        let level = margin.map {
            "the clip's \(isEnd ? "last" : "first") 25 ms is " + ($0 < 1 ? "at speech level" : "\(String(format: "%.1f", $0)) dB under the speech")
        } ?? ""
        var cut = CheckProblem.CutEdge(clipID: clip.id, edge: edge.edge, margin: margin)
        guard verdict.clipped else {
            return CheckProblem(
                kind: .marginalJoin, start: edge.time, end: edge.time,
                message: "Marginal join \(place): \(level) (clean is \(Int(CutAudit.cleanFrom)) or more, clipped under \(Int(CutAudit.clippedUnder))). Listen to it with tandem clip.",
                clipIDs: clipIDs, cut: cut
            )
        }

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
        if !level.isEmpty { what += "; \(level)" }

        let reach = String(format: "%.1f", CutAudit.reach)
        var advice = "No pause within \(reach) s either side: listen with tandem clip and recut it by hand."
        cut.fixKind = .nothingNearby
        if verdict.fix == .putBack, let outgoing = edge.outgoing, let removed = edge.removed {
            let length = removed.upperBound - removed.lowerBound
            let to = outgoing.end + Time(seconds: length / outgoing.speed)
            cut.fixKind = .putBack
            cut.fix = .trim(clipID: outgoing.id, edge: .end, to: to, ripple: true, includeLinked: nil)
            advice = "No pause it can reach without bringing back a cut word: put back the \(String(format: "%.2f", length)) s cut here, filler and all (the end of \(outgoing.id) \(String(format: "%.3f", (to - outgoing.end).seconds)) s later)."
        } else if let delta = shift(edge, verdict, project: project) {
            let to = edge.time + delta
            cut.fixKind = .trimToPause
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
        } else if verdict.lost != nil || verdict.kept <= CutAudit.reach {
            // There's a pause in reach, but moving there brings a cut word
            // back or drops a kept one.
            let tooLong = edge.removed.map { " The \(String(format: "%.2f", $0.upperBound - $0.lowerBound)) s cut here is too long to put back." } ?? ""
            advice = "No pause within \(reach) s that doesn't bring back a cut word or drop a kept one.\(tooLong) Listen with tandem clip and recut it by hand."
        }
        return CheckProblem(
            kind: .clippedWord, start: edge.time, end: edge.time,
            message: "Clipped word \(place): \(what). \(advice)",
            clipIDs: clipIDs, cut: cut
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
