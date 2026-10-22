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
/// Each edge is `{"id", "file", "edge", "keeps": "before"|"after",
/// "removed": [start, end] or null, "label": "clipped"|"marginal"|"clean",
/// "fixedEdge", "kind"}`, times in the file's own media time.
final class CutScorecardTests: XCTestCase {
    struct Labelled: Decodable {
        var id: String
        var file: String
        var edge: Double
        var keeps: String
        var removed: [Double]?
        var label: String
        var fixedEdge: Double?
        var kind: String?
    }

    /// The speech level's 3 s either side of an edge, and room to reach a pause.
    private static let around = 3.4

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

        var lines = ["Cut scorecard: \(results.count) edges"]
        for label in ["clipped", "marginal", "clean"] {
            let these = results.filter { $0.0.label == label }
            guard !these.isEmpty else { continue }
            let counts = Dictionary(grouping: these, by: { $0.1.verdict }).mapValues(\.count)
            lines.append("  labelled \(label) (\(these.count)): judged clipped \(counts[.clipped] ?? 0), marginal \(counts[.marginal] ?? 0), clean \(counts[.clean] ?? 0)")
        }
        let caught = results.filter { $0.0.label == "clipped" && $0.1.clipped }
        let fixes = Dictionary(grouping: caught, by: { fixName($0.1.fix) }).mapValues(\.count)
        lines.append("  fixes for caught clipped edges: " + fixes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let offsets = caught.compactMap { pair -> Double? in
            guard let to = pair.1.suggestion, let fixed = pair.0.fixedEdge else { return nil }
            return abs(to - fixed)
        }.sorted()
        if !offsets.isEmpty {
            lines.append(String(
                format: "  trims against the fix that worked (%d): median %.0f ms, within 50 ms %d, over 150 ms %d",
                offsets.count, offsets[offsets.count / 2] * 1000, offsets.filter { $0 <= 0.05 }.count, offsets.filter { $0 > 0.15 }.count
            ))
        }

        func row(_ pair: (Labelled, CutAudit.Edge)) -> String {
            let (labelled, edge) = pair
            let margin = edge.margin.map { String(format: "%5.1f dB", $0) } ?? "   -    "
            let to = edge.suggestion.map { String(format: "%.3f", $0) } ?? "-"
            let fixed = labelled.fixedEdge.map { String(format: "%.3f", $0) } ?? "-"
            return "    \(labelled.id) \(String(format: "%.3f", labelled.edge)) keeps \(labelled.keeps): \(edge.verdict.rawValue), \(margin), fix \(fixName(edge.fix)) \(to) (worked: \(fixed)) [\(labelled.kind ?? "")]"
        }
        let missed = results.filter { $0.0.label == "clipped" && !$0.1.clipped }
        let falseAlarms = results.filter { $0.0.label == "clean" && $0.1.clipped }
        lines.append("  missed clipped edges (\(missed.count)):")
        lines += missed.map(row)
        lines.append("  clean edges flagged (\(falseAlarms.count)):")
        lines += falseAlarms.map(row)
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(results.isEmpty)
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
