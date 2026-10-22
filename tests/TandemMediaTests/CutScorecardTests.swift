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
/// Each edge is `{"id", "file", "edge", "keeps": "before"|"after",
/// "removed": [start, end] or null, "label": "clipped"|"marginal"|"clean",
/// "fixedEdge", "fix", "kind"}`, times in the file's own media time.
/// `fixedEdge` is where the edit moved the edge (null where the cut was put
/// back), and when an edge there is labelled too, it's that edge's fix that
/// counts: on the Ian video most of the first round's fixes were flagged
/// again and put back in the second.
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

        /// Mike heard something an audio check can't: a sentence left
        /// hanging, an off-mic question, a breath cut short.
        var isEditorial: Bool { kind.map { $0.hasPrefix("editorial") || $0.hasPrefix("other") } ?? false }
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

        // Levels per file from every window read, as `tandem check --cuts`
        // works them out per take.
        var results: [(Labelled, CutAudit.Edge)] = []
        for (file, group) in Dictionary(grouping: edges, by: \.file).sorted(by: { $0.key < $1.key }) {
            let url = media.appendingPathComponent(file)
            let windows = try group.map { try energy(url, from: $0.edge - Self.around, to: $0.edge + Self.around) }
            let levels = SpeechLevels(of: windows)
            for (labelled, window) in zip(group, windows) {
                let removed = labelled.removed.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }
                let side: CutAudit.Side = labelled.keeps == "before" ? .before : .after
                results.append((labelled, CutAudit.judge(window, levels: levels, at: labelled.edge, keeps: side, removed: removed)))
            }
        }
        results.sort { ($0.0.file, $0.0.edge) < ($1.0.file, $1.0.edge) }

        var lines = ["Cut scorecard: \(results.count) edges"]
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
            return "    \(labelled.id) \(String(format: "%.3f", labelled.edge)) keeps \(labelled.keeps): \(edge.verdict.rawValue), \(margin), lost \(lost), gap \(gap), fix \(fixName(edge.fix)) \(to) (worked: \(fixed)) [\(labelled.kind ?? "")]"
        }
        let missed = results.filter { $0.0.label == "clipped" && !$0.1.clipped }
        let falseAlarms = results.filter { $0.0.label == "clean" && $0.1.clipped }
        lines.append("  clipped edges not judged clipped (\(missed.count)):")
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

    /// Follows an edge's fix on to the labelled edge it made, if any, and
    /// says what finally worked there.
    static func worked(_ edge: Labelled, in edges: [Labelled]) -> Worked {
        var current = edge
        var seen: Set<String> = [edge.id]
        while let fixed = current.fixedEdge {
            guard let next = edges.first(where: {
                !seen.contains($0.id) && $0.file == current.file && $0.keeps == current.keeps && abs($0.edge - fixed) < 0.0015
            }) else { return .trim(fixed) }
            seen.insert(next.id)
            current = next
        }
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
