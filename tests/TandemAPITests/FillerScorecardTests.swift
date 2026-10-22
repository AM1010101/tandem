import XCTest
@testable import TandemAPI
@testable import TandemCore
@testable import TandemMedia

/// How `tandem cut --fillers` does on a real take, alone and with tighten
/// in either order: fillers found, cut and left in (and why), seconds
/// removed, and every join it leaves judged by `CutPlacer.judge` on the raw
/// mic with the transcript's words, as `tandem check --cuts` judges it.
/// Ian's uncut whiteboard take (#64), transcribed by Bark, is the take it
/// was made for.
///
/// Opt-in, and it prints a scorecard rather than asserting thresholds:
///
///     TANDEM_FILLERS_PROJECT="<…>/ian-whiteboard/Ian Whiteboard.tandem" \
///       swift test --filter FillerScorecardTests
///
/// It edits a copy in memory (`ScorecardProject`) and never saves it. Add
/// TANDEM_FILLERS_ALL=1 for a line on every filler left in and every join
/// that isn't clean.
final class FillerScorecardTests: XCTestCase {
    struct Joins {
        var count = 0
        var verdicts: [CutAudit.Verdict: Int] = [:]
        var lines: [String] = []

        var text: String {
            [CutAudit.Verdict.clipped, .marginal, .clean].map { "\(verdicts[$0, default: 0]) \($0.rawValue)" }.joined(separator: " / ")
        }
    }

    func testScorecard() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TANDEM_FILLERS_PROJECT"] ?? environment["TANDEM_TIGHTEN_PROJECT"] else {
            throw XCTSkip("set TANDEM_FILLERS_PROJECT to a .tandem project to score cut --fillers")
        }
        let all = environment["TANDEM_FILLERS_ALL"] == "1"
        let opened = try ScorecardProject(path: path)
        defer { opened.close() }
        let service = opened.service
        let context = CallContext(author: "scorecard")
        let levels = opened.voices.mapValues { SpeechLevels(of: [$0]) }
        let before = service.coordinator.project

        /// Every join between voice clips on the timeline, both sides
        /// judged with the transcript's words; the worse side is the join's.
        func judgeJoins(_ project: Project) -> Joins {
            var joins = Joins()
            let rank: [CutAudit.Verdict: Int] = [.clean: 0, .marginal: 1, .clipped: 2]
            for track in TranscriptTools.speechTracks(project) {
                let clips = track.clips.filter(TranscriptTools.isHeard).sorted { $0.start < $1.start }
                for (left, right) in zip(clips, clips.dropFirst()) where left.end == right.start {
                    guard let a = left.mediaID, let b = right.mediaID, let ea = opened.voices[a], let eb = opened.voices[b] else { continue }
                    let from = left.sourceEnd.seconds, to = right.sourceStart.seconds
                    // A through-edit isn't a join anyone hears.
                    if a == b, abs(to - from) < 1e-6 { continue }
                    let removed = a == b && from < to ? from...to : nil
                    func words(_ id: String, near time: Double) -> [CutAudit.Word] {
                        (opened.analysis.transcripts[id]?.words ?? [])
                            .filter { $0.end.seconds > time - 5 && $0.start.seconds < time + 5 }
                            .map { CutAudit.Word(text: $0.text, start: $0.start.seconds, end: $0.end.seconds) }
                    }
                    let startEdge = CutPlacer(ea, levels: levels[a]!).judge(at: from, keeps: .before, removed: removed, transcript: words(a, near: from))
                    let endEdge = CutPlacer(eb, levels: levels[b]!).judge(at: to, keeps: .after, removed: removed, transcript: words(b, near: to))
                    let verdict = rank[startEdge.verdict]! >= rank[endEdge.verdict]! ? startEdge.verdict : endEdge.verdict
                    joins.count += 1
                    joins.verdicts[verdict, default: 0] += 1
                    if verdict != .clean {
                        func margin(_ edge: CutAudit.Edge) -> String { edge.margin.map { String(format: "%.1f", $0) } ?? "pause" }
                        joins.lines.append("    \(left.end)  start \(startEdge.verdict.rawValue) \(margin(startEdge)), end \(endEdge.verdict.rawValue) \(margin(endEdge))")
                    }
                }
            }
            return joins
        }
        func reasons(_ fillers: CutFillers?) -> String {
            guard let fillers else { return "" }
            return fillers.leftIn.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        }
        func fillerRow(_ name: String, _ result: CutResult) -> String {
            let fillers = result.fillers
            return String(
                format: "  %@: %d found, %d cut, %d left in (%@), %.1f s removed by fillers",
                name, fillers?.found ?? 0, fillers?.cut ?? 0, fillers?.leftIn.values.reduce(0, +) ?? 0, reasons(fillers), fillers?.removed.seconds ?? 0
            )
        }

        var lines = ["cut --fillers scorecard on \(opened.original.lastPathComponent) (in memory, never saved)"]
        let names = Dictionary(grouping: opened.analysis.transcripts.values.flatMap(\.words).compactMap { TranscriptTools.filler($0.text) }, by: { $0 }).mapValues(\.count)
        lines.append("  the transcripts have " + names.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + " (the voice track plays \(TimeText.duration(TranscriptTools.speechTracks(before).flatMap(\.clips).reduce(.zero) { $0 + $1.duration })) of them)")

        // Tighten alone, for comparison.
        let tightenAlone = try await service.tighten(TightenRequest(mike: true), context: context)
        let tightenSeconds = tightenAlone.cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        lines.append(String(format: "  tighten --mike alone: %d cuts, %.1f s removed (the old transcript-gap tighten removed 143.8 s)", tightenAlone.cuts.count, tightenSeconds))

        // 1. Fillers alone, applied to the copy so every join can be judged.
        let fillers = try await service.cut(CutRequest(remove: [], fillers: true), context: context)
        lines.append(fillerRow("fillers alone (dry run)", fillers))
        if all {
            for stretch in fillers.cuts where stretch.status == .kept {
                lines.append("    left in \(stretch.start)-\(stretch.end) \"\(stretch.text)\" \(stretch.problem?.rawValue ?? "") ...\(stretch.before) | \(stretch.after)...")
            }
        }
        _ = try await service.cut(CutRequest(remove: [], fillers: true, apply: true), context: context)
        let fillerJoins = judgeJoins(service.coordinator.project)
        lines.append(String(format: "    %d stretches cut, %.1f s removed in all; joins %@", fillers.cuts.filter { $0.status == .cut }.count, fillers.removed.seconds, fillerJoins.text))
        if all { lines += fillerJoins.lines }

        // 2. Fillers, then tighten on what's left (what the docs recommend).
        let then = try await service.tighten(TightenRequest(mike: true, apply: true), context: context)
        let thenSeconds = then.cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        let firstJoins = judgeJoins(service.coordinator.project)
        let firstTotal = (before.duration - service.coordinator.project.duration).seconds
        lines.append(String(
            format: "  fillers then tighten: %.1f s + %.1f s (%d tighten cuts) = %.1f s removed (%+.1f s on tighten alone, %+.1f s on the old tighten); joins %@",
            fillers.removed.seconds, thenSeconds, then.cuts.count, firstTotal, firstTotal - tightenSeconds, firstTotal - 143.8, firstJoins.text
        ))
        if all { lines += firstJoins.lines }
        for _ in 0..<2 { XCTAssertNotNil(service.coordinator.undo()) }
        XCTAssertEqual(service.coordinator.project, before)

        // 3. Tighten, then fillers on the tightened take.
        _ = try await service.tighten(TightenRequest(mike: true, apply: true), context: context)
        let after = try await service.cut(CutRequest(remove: [], fillers: true, apply: true), context: context)
        let secondJoins = judgeJoins(service.coordinator.project)
        let secondTotal = (before.duration - service.coordinator.project.duration).seconds
        lines.append(fillerRow("tighten then fillers", after))
        lines.append(String(
            format: "    %.1f s + %.1f s = %.1f s removed (%+.1f s on tighten alone, %+.1f s on the old tighten); joins %@",
            tightenSeconds, after.removed.seconds, secondTotal, secondTotal - tightenSeconds, secondTotal - 143.8, secondJoins.text
        ))
        if all { lines += secondJoins.lines }
        for _ in 0..<2 { XCTAssertNotNil(service.coordinator.undo()) }
        XCTAssertEqual(service.coordinator.project, before)

        // What the command prints, on a stretch of the take.
        let sample = try await service.cut(CutRequest(remove: [], fillers: true, from: t(120), to: t(240)), context: context)
        lines.append("  tandem cut --fillers --from 2:00 --to 4:00 prints:")
        lines += sample.readableText.split(separator: "\n").map { "    | \($0)" }
        print(lines.joined(separator: "\n"))
    }
}
