import AVFoundation
import XCTest
@testable import TandemMedia

/// How `CutAudit` does on the cut edges of a real edit, labelled by ear and
/// by measurement: how many clipped edges it catches, how many clean ones it
/// flags, and how near its trims land to the fixes that worked. The Ian
/// whiteboard video's 124 edges (#64) are the set it was made for.
///
/// Opt-in, and it prints a scorecard rather than asserting thresholds:
///
///     TANDEM_CUT_EDGES=<edges.json> TANDEM_CUT_MEDIA=<folder of the files they name> \
///       swift test --filter CutScorecardTests
///
/// Add TANDEM_CUT_ALL=1 for a line on every edge, not just the misses.
///
/// TANDEM_CUT_WORDS=<folder> scores it with a transcript: one JSON per
/// file, named for it (`<name>.json` for `<name>.wav`), as
/// `{"words": [{"start", "end", "text"}]}` in the engine's own times.
/// TANDEM_CUT_ALIGN=1 aligns them to the file's sound first, as Tandem does
/// when it reads a transcript (`TranscriptAlignment`).
///
/// Each edge is `{"id", "file", "edge", "keeps": "before"|"after",
/// "removed": [start, end] or null, "label": "clipped"|"marginal"|"clean",
/// "fixedEdge", "fix", "kind"}`, times in the file's own media time.
/// `fixedEdge` is where the edit moved the edge (null where the cut was put
/// back), and when an edge there is labelled too, it's that edge's fix that
/// counts: on the Ian video most of the first round's fixes were flagged
/// again and put back in the second. The final cut's set adds `source`
/// (`heard`: Mike heard it clipped; `fixed`: an agent fixed it; `approved`:
/// a join in the final cut) and `under` (music or a sound effect playing
/// over an approved join).
final class CutScorecardTests: XCTestCase {
    struct Labelled: Decodable {
        var id: String
        var file: String
        var edge: Double
        var keeps: String
        var removed: [Double]?
        var label: String
        var fixedEdge: Double?
        var fix: String?
        var kind: String?
        var source: String?
        var under: [String]?
        var fixedBy: String?

        /// Mike heard something an audio check can't: a sentence left
        /// hanging, an off-mic question, a breath cut short, a leftover
        /// fragment of a cut phrase.
        var isEditorial: Bool {
            kind.map { $0.hasPrefix("editorial") || $0.hasPrefix("other") || $0 == "fragment" || $0 == "halfThought" } ?? false
        }
    }

    /// What finally worked for an edge: a trim to a time, or putting the
    /// cut back.
    enum Worked: Equatable {
        case trim(Double)
        case putBack
        case unknown
    }

    /// The speech level and floor's 3 s either side of an edge, and room to
    /// reach a pause.
    private static let around = CutAudit.around + CutAudit.reach

    func testScorecard() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let edgesPath = environment["TANDEM_CUT_EDGES"], let mediaPath = environment["TANDEM_CUT_MEDIA"] else {
            throw XCTSkip("set TANDEM_CUT_EDGES and TANDEM_CUT_MEDIA to score the cut check")
        }
        let edges = try JSONDecoder().decode([Labelled].self, from: Data(contentsOf: URL(fileURLWithPath: edgesPath)))
        let media = URL(fileURLWithPath: mediaPath, isDirectory: true)
        let wordsFolder = environment["TANDEM_CUT_WORDS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let align = environment["TANDEM_CUT_ALIGN"] == "1"

        // Levels per file from every window read, as `tandem check --cuts`
        // works them out per take.
        var results: [(Labelled, CutAudit.Edge)] = []
        for (file, group) in Dictionary(grouping: edges, by: \.file).sorted(by: { $0.key < $1.key }) {
            let url = media.appendingPathComponent(file)
            let words = try wordsFolder.map {
                try BarkWords.load($0.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json"), aligningTo: align ? url : nil)
            }
            let windows = try group.map { try energy(url, from: $0.edge - Self.around, to: $0.edge + Self.around) }
            let levels = SpeechLevels(of: windows)
            for (labelled, window) in zip(group, windows) {
                let removed = labelled.removed.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }
                let side: CutAudit.Side = labelled.keeps == "before" ? .before : .after
                let edge: CutAudit.Edge
                if let words {
                    // As `tandem check --cuts` passes them: the words its 3 s
                    // either side of the edge reach.
                    let near = (labelled.edge - CutAudit.around)...(labelled.edge + CutAudit.around)
                    let nearby = words.filter { $0.range.overlaps(near) }
                    edge = CutAudit.judge(window, levels: levels, at: labelled.edge, keeps: side, removed: removed, transcript: nearby)
                } else {
                    edge = CutAudit.judge(window, levels: levels, at: labelled.edge, keeps: side, removed: removed)
                }
                results.append((labelled, edge))
            }
        }
        results.sort { ($0.0.file, $0.0.edge) < ($1.0.file, $1.0.edge) }

        var lines = ["Cut scorecard: \(results.count) edges, " + (wordsFolder == nil ? "no transcript" : align ? "aligned transcript" : "transcript in the engine's times")]
        if results.contains(where: { $0.0.source != nil }) { lines += bySource(results, edges: edges) }
        for label in ["clipped", "marginal", "clean"] {
            for editorial in [false, true] {
                let these = results.filter { $0.0.label == label && $0.0.isEditorial == editorial }
                guard !these.isEmpty else { continue }
                let counts = Dictionary(grouping: these, by: { $0.1.verdict }).mapValues(\.count)
                let what = editorial ? "editorial or other, no audio check can hear these" : "acoustic"
                lines.append("  labelled \(label), \(what) (\(these.count)): judged clipped \(counts[.clipped] ?? 0), marginal \(counts[.marginal] ?? 0), clean \(counts[.clean] ?? 0)")
            }
        }
        let caught = results.filter { $0.0.label == "clipped" && $0.1.clipped }
        let fixes = Dictionary(grouping: caught, by: { fixName($0.1.fix) }).mapValues(\.count)
        lines.append("  fixes for caught clipped edges: " + fixes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        let worked = caught.map { ($0, Self.worked($0.0, in: edges)) }
        let trimsThatWorked = worked.filter { if case .trim = $0.1 { true } else { false } }
        let offsets = trimsThatWorked.compactMap { pair -> Double? in
            guard case .trim(let fixed) = pair.1, let to = pair.0.1.suggestion else { return nil }
            return abs(to - fixed)
        }.sorted()
        lines.append(String(
            format: "  caught edges the edit fixed with a trim (%d): trimmed %d, median %.0f ms from it, within 60 ms %d, over 150 ms %d",
            trimsThatWorked.count, offsets.count, offsets.isEmpty ? 0 : offsets[offsets.count / 2] * 1000,
            offsets.filter { $0 <= 0.0605 }.count, offsets.filter { $0 > 0.15 }.count
        ))
        let putBack = worked.filter { $0.1 == .putBack }
        let putBackFixes = Dictionary(grouping: putBack, by: { fixName($0.0.1.fix) }).mapValues(\.count)
        lines.append("  caught edges the edit put back (\(putBack.count)): " + putBackFixes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            + " (with no transcript here, a trim can't tell it's bringing a cut word back)")

        func row(_ pair: (Labelled, CutAudit.Edge)) -> String {
            let (labelled, edge) = pair
            let margin = edge.margin.map { String(format: "%5.1f dB", $0) } ?? "  pause "
            let lost = edge.lost.map { String(format: "%.2f", $0) } ?? "-"
            let gap = edge.gap.map { String(format: "%.3f", $0) } ?? "-"
            let to = edge.suggestion.map { String(format: "%.3f", $0) } ?? ""
            let fixed: String
            switch Self.worked(labelled, in: edges) {
            case .trim(let time): fixed = String(format: "trim %.3f", time) + (edge.suggestion.map { String(format: ", %+.0f ms", ($0 - time) * 1000) } ?? "")
            case .putBack: fixed = "putBack"
            case .unknown: fixed = "-"
            }
            return "    \(labelled.id) \(String(format: "%.3f", labelled.edge)) keeps \(labelled.keeps): \(edge.verdict.rawValue), \(margin), lost \(lost), gap \(gap), fix \(fixName(edge.fix)) \(to)\(edge.betweenWords ? " between words" : "")\(edge.drops.map { " drops \"\($0)\"" } ?? "") (worked: \(fixed)) [\(labelled.kind ?? "")\(labelled.under.map { " under " + $0.joined(separator: "+") } ?? "")]"
        }
        let missed = results.filter { $0.0.label == "clipped" && !$0.1.clipped && $0.0.source != "fixed" }
        let falseAlarms = results.filter { $0.0.label == "clean" && $0.1.clipped }
        lines.append("  clipped edges not judged clipped (\(missed.count))" + (results.contains { $0.0.source == "fixed" } ? ", leaving out the ones an agent fixed:" : ":"))
        lines += missed.map(row)
        lines.append("  clean edges flagged (\(falseAlarms.count)):")
        lines += falseAlarms.map(row)
        if environment["TANDEM_CUT_ALL"] == "1" {
            for label in ["clipped", "marginal", "clean"] {
                lines.append("  every \(label) edge:")
                lines += results.filter { $0.0.label == label }.map(row)
            }
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(results.isEmpty)
    }

    /// How `CutPlanner` (`tandem cut`) does on the same edit: for every
    /// labelled join cut out of one file (it has a `removed` range), plan
    /// removing that same stretch from the sound alone. The set has no
    /// transcript, so the removed range's ends stand in for the words'
    /// times, as they are and shifted by up to 0.2 s either way, as off as
    /// SpeechAnalyzer was on the Ian video (#64).
    func testPlannerScorecard() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let edgesPath = environment["TANDEM_CUT_EDGES"], let mediaPath = environment["TANDEM_CUT_MEDIA"] else {
            throw XCTSkip("set TANDEM_CUT_EDGES and TANDEM_CUT_MEDIA to score the cut planner")
        }
        let edges = try JSONDecoder().decode([Labelled].self, from: Data(contentsOf: URL(fileURLWithPath: edgesPath)))
        let media = URL(fileURLWithPath: mediaPath, isDirectory: true)

        /// One join: a stretch cut out of a file, and the labelled edges
        /// either side of it.
        struct Join {
            var file: String
            var removed: ClosedRange<Double>
            var edges: [Labelled]
            var clipped: Bool { edges.contains { $0.label == "clipped" } }
        }
        var joins: [Join] = []
        for edge in edges {
            guard let range = edge.removed, range.count == 2, range[1] > range[0] else { continue }
            let removed = range[0]...range[1]
            if let index = joins.firstIndex(where: { $0.file == edge.file && abs($0.removed.lowerBound - removed.lowerBound) < 0.0015 && abs($0.removed.upperBound - removed.upperBound) < 0.0015 }) {
                joins[index].edges.append(edge)
            } else {
                joins.append(Join(file: edge.file, removed: removed, edges: [edge]))
            }
        }
        joins.sort { ($0.file, $0.removed.lowerBound) < ($1.file, $1.removed.lowerBound) }

        // The sound either side of each join's two edges, with room for the
        // floor, the speech level and the shifts.
        let around = CutAudit.around + CutAudit.reach + CutPlanner.slack + 0.2
        var placers: [String: (start: CutPlacer, end: CutPlacer)] = [:]
        for (file, group) in Dictionary(grouping: joins, by: \.file) {
            let url = media.appendingPathComponent(file)
            var windows: [(String, SpeechEnergy, SpeechEnergy)] = []
            for join in group {
                let key = "\(join.removed)"
                windows.append((key,
                    try energy(url, from: join.removed.lowerBound - around, to: join.removed.lowerBound + around),
                    try energy(url, from: join.removed.upperBound - around, to: join.removed.upperBound + around)))
            }
            let levels = SpeechLevels(of: windows.flatMap { [$0.1, $0.2] })
            for (key, start, end) in windows { placers[file + key] = (CutPlacer(start, levels: levels), CutPlacer(end, levels: levels)) }
        }

        func plan(_ join: Join, shift: Double) -> CutPlan {
            let placer = placers[join.file + "\(join.removed)"]!
            let from = join.removed.lowerBound + shift, to = join.removed.upperBound + shift
            return CutPlanner.plan(
                start: placer.start, CutPlanner.Boundary(time: from), end: placer.end, CutPlanner.Boundary(time: to),
                keep: 0.08, falseStart: to - from > CutPlanner.falseStartFrom
            )
        }
        func kind(_ plan: CutPlan) -> String {
            if plan.cuts { return plan.falseStart ? "falseStart" : "clean" }
            return plan.problem?.rawValue ?? "?"
        }

        var lines = ["Cut planner scorecard: \(joins.count) joins cut out of one file (\(joins.filter(\.clipped).count) with a clipped edge)"]
        for shift in [0, -0.1, 0.1, -0.2, 0.2] {
            let kinds = Dictionary(grouping: joins.map { kind(plan($0, shift: shift)) }, by: { $0 }).mapValues(\.count)
            lines.append(String(format: "  ends shifted %+.1f s: ", shift) + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }

        // Against what finally worked, unshifted and shifted, every edge.
        for shift in [0, -0.2, 0.2] {
            var offsets: [Double] = []
            var putBackAndKept = 0, putBackButCut = 0
            var clippedCut = 0, clippedKept = 0, clippedNotClean = 0, clippedNear = 0
            for join in joins {
                let result = plan(join, shift: shift)
                let worked = join.edges.map { Self.worked($0, in: edges) }
                var near = true
                for (labelled, fix) in zip(join.edges, worked) {
                    guard case .trim(let time) = fix, result.cuts, let planned = labelled.keeps == "before" ? result.from : result.to else { continue }
                    offsets.append(abs(planned - time))
                    near = near && abs(planned - time) <= 0.0605
                }
                if worked.contains(.putBack) { if result.cuts { putBackButCut += 1 } else { putBackAndKept += 1 } }
                guard join.clipped else { continue }
                if result.cuts {
                    clippedCut += 1
                    if near { clippedNear += 1 }
                } else if result.problem == .notClean {
                    clippedNotClean += 1
                } else {
                    clippedKept += 1
                }
            }
            offsets.sort()
            lines.append(String(format: "  shifted %+.1f s:", shift))
            lines.append(String(
                format: "    planned edges against the fix that worked (%d): median %.0f ms, within 60 ms %d, over 150 ms %d",
                offsets.count, offsets.isEmpty ? 0 : offsets[offsets.count / 2] * 1000, offsets.filter { $0 <= 0.0605 }.count, offsets.filter { $0 > 0.15 }.count
            ))
            lines.append("    joins the edit put back: planner kept \(putBackAndKept), cut pause to pause \(putBackButCut)")
            lines.append("    clipped joins avoided: \(clippedCut + clippedKept) of \(joins.filter(\.clipped).count) (cut clean pause to pause \(clippedCut), \(clippedNear) of them within 60 ms of every fix that worked; kept \(clippedKept)); planned but not clean \(clippedNotClean)")
        }

        lines.append("  every join, unshifted (planned from-to, fixes that worked):")
        for join in joins {
            let result = plan(join, shift: 0)
            let planned = result.from.map { String(format: "%.3f-%.3f", $0, result.to ?? 0) } ?? "-"
            let worked = join.edges.map { labelled -> String in
                switch Self.worked(labelled, in: edges) {
                case .trim(let time): return "\(labelled.keeps) trim " + String(format: "%.3f", time)
                case .putBack: return "\(labelled.keeps) putBack"
                case .unknown: return "\(labelled.keeps) -"
                }
            }.joined(separator: ", ")
            let margins = [result.start?.margin, result.end?.margin].map { $0.map { String(format: "%.0f", $0) } ?? "-" }.joined(separator: "/")
            let labels = join.edges.map(\.label).joined(separator: "+")
            lines.append(String(format: "    %@ %.3f-%.3f [%@]: %@ %@ margins %@ (worked: %@)", join.file.prefix(24).description, join.removed.lowerBound, join.removed.upperBound, labels, kind(result), planned, margins, worked))
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(joins.isEmpty)
    }

    /// The final cut's set by where each edge came from: what Mike heard,
    /// by kind; the joins he approved that are flagged, plain and under
    /// music or a sound effect; and how near the fixes land to the ones the
    /// edit made.
    private func bySource(_ results: [(Labelled, CutAudit.Edge)], edges: [Labelled]) -> [String] {
        var lines: [String] = []
        let heard = results.filter { $0.0.source == "heard" }
        for kind in Array(Set(heard.compactMap(\.0.kind))).sorted() {
            let these = heard.filter { $0.0.kind == kind }
            let what = these[0].0.isEditorial ? " (content, no audio check hears it)" : ""
            lines.append("  heard \(kind)\(what): caught \(these.filter(\.1.clipped).count) of \(these.count)" + (these.contains { $0.1.verdict == .marginal } ? ", marginal \(these.filter { $0.1.verdict == .marginal }.count)" : ""))
        }
        let acoustic = heard.filter { !$0.0.isEditorial }
        lines.append("  heard, acoustic: caught \(acoustic.filter(\.1.clipped).count) of \(acoustic.count)")
        let fixed = results.filter { $0.0.source == "fixed" }
        lines.append("  fixed by an agent: judged clipped \(fixed.filter(\.1.clipped).count) of \(fixed.count), marginal \(fixed.filter { $0.1.verdict == .marginal }.count) ("
            + Array(Set(fixed.compactMap(\.0.kind))).sorted().map { kind in "\(kind) \(fixed.filter { $0.0.kind == kind && $0.1.clipped }.count) of \(fixed.filter { $0.0.kind == kind }.count)" }.joined(separator: ", ") + ")")
        let approved = results.filter { $0.0.source == "approved" }
        let plain = approved.filter { ($0.0.under ?? []).isEmpty }, under = approved.filter { !($0.0.under ?? []).isEmpty }
        lines.append("  approved flagged: \(approved.filter(\.1.clipped).count) of \(approved.count) (plain \(plain.filter(\.1.clipped).count) of \(plain.count), under music or sfx \(under.filter(\.1.clipped).count) of \(under.count)); marginal \(approved.filter { $0.1.verdict == .marginal }.count)")
        for source in ["heard", "fixed"] {
            let caught = results.filter { $0.0.source == source && !$0.0.isEditorial && $0.1.clipped }
            let offsets = caught.compactMap { pair -> Double? in
                guard case .trim(let fixed) = Self.worked(pair.0, in: edges), let to = pair.1.suggestion else { return nil }
                return abs(to - fixed)
            }.sorted()
            let withTrim = caught.filter { if case .trim = Self.worked($0.0, in: edges) { true } else { false } }.count
            let putBack = caught.filter { Self.worked($0.0, in: edges) == .putBack || $0.0.fixedBy == "putBack" }
            lines.append(String(
                format: "  %@ and caught, where the edit trimmed (%d): trimmed too %d, median %.0f ms from it, within 60 ms %d, over 150 ms %d; where it put the cut back (%d): ",
                source, withTrim, offsets.count, offsets.isEmpty ? 0 : offsets[offsets.count / 2] * 1000, offsets.filter { $0 <= 0.0605 }.count, offsets.filter { $0 > 0.15 }.count, putBack.count
            ) + Dictionary(grouping: putBack, by: { fixName($0.1.fix) }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return lines
    }

    /// Follows an edge's fix on to the labelled edge it made, if any, and
    /// says what finally worked there.
    static func worked(_ edge: Labelled, in edges: [Labelled]) -> Worked {
        var current = edge
        var seen: Set<String> = [edge.id]
        while let fixed = current.fixedEdge {
            guard let next = edges.first(where: {
                !seen.contains($0.id) && $0.file == current.file && $0.keeps == current.keeps && abs($0.edge - fixed) < 0.0015
            }) else { return .trim(fixed) }
            // A join in the final cut is where the fix ended up.
            if next.source == "approved" { return .trim(next.edge) }
            seen.insert(next.id)
            current = next
        }
        if current.fixedBy == "putBack" { return .putBack }
        return current.fix?.contains("restor") == true ? .putBack : .unknown
    }

    private func fixName(_ fix: CutAudit.Fix?) -> String {
        switch fix {
        case .trim: "trim"
        case .putBack: "putBack"
        case .nothingNearby: "nothingNearby"
        case nil: "none"
        }
    }

    /// Frames of the file from `from` to `to`, read straight from there.
    private func energy(_ url: URL, from: Double, to: Double) throws -> SpeechEnergy {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let start = max(0, from)
        file.framePosition = AVAudioFramePosition((start * rate).rounded())
        let count = AVAudioFrameCount(((to - start) * rate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        return SpeechEnergy(samples: samples, sampleRate: rate, start: start)
    }
}
