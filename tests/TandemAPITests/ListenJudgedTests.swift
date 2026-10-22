import XCTest
@testable import TandemAPI
@testable import TandemCore
@testable import TandemMedia

/// How `check --cuts --listen` weighs its evidence (`CutEvidence`) on a
/// saved run judged by hand: Mike's published Tandem video, where the run
/// before it flagged 38 of 257 joins and reading each one again found 4
/// real, 30 false and 4 unsure.
///
/// Opt-in, and it prints a scorecard rather than asserting thresholds:
///
///     TANDEM_LISTEN_JUDGED=<…>/tandem-video/listen-check-2026-10-22.json \
///     TANDEM_LISTEN_LABELS=tests/fixtures-local/tandem-video-listen-labels.json \
///     TANDEM_LISTEN_PROJECT=<…>/tandem-video/Tandem.tandem \
///       swift test --filter ListenJudgedTests
///
/// The JSON is the full `check --cuts --listen --json` result from before
/// the evidence was weighed: its problems, notes and every join heard. The
/// labels are `[{"time", "verdict": "real"|"false"|"unsure", "words"}]`, a
/// row per flagged join. Nothing is rendered or heard again.
///
/// A saved run from before `HeardJoin.cut` has no cut words beside each
/// join, so TANDEM_LISTEN_PROJECT works them out from the project and its
/// cached transcripts, as `check` does (`CutCheck.cutWords`), in the
/// transcript's own times: the check aligns them to the voice first, which
/// reads the sound.
final class ListenJudgedTests: XCTestCase {
    struct Label: Decodable {
        var time: Double
        var verdict: String
        var words: String
    }

    func testJudgedListenScorecard() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let judgedPath = environment["TANDEM_LISTEN_JUDGED"], let labelsPath = environment["TANDEM_LISTEN_LABELS"] else {
            throw XCTSkip("set TANDEM_LISTEN_JUDGED and TANDEM_LISTEN_LABELS to score the combined check on a judged run")
        }
        let saved = try JSONDecoder().decode(CheckResult.self, from: Data(contentsOf: URL(fileURLWithPath: judgedPath)))
        let labels = try JSONDecoder().decode([Label].self, from: Data(contentsOf: URL(fileURLWithPath: labelsPath)))
        var summary = try XCTUnwrap(saved.listened, "the saved run has no listened joins")
        var lines: [String] = []

        if let projectPath = environment["TANDEM_LISTEN_PROJECT"] {
            let (project, revision) = try ProjectFile.load(from: URL(fileURLWithPath: projectPath))
            if revision != saved.revision { lines.append("  (the project is at revision \(revision), the saved run at \(saved.revision ?? -1): cut words may differ)") }
            let words = try cachedWords(project, folder: URL(fileURLWithPath: projectPath).deletingLastPathComponent())
            let edges = CutCheck.edges(in: project, ranges: [TimeRange(start: .zero, end: project.duration)])
            let tolerance = project.settings.frameRate.flicksPerFrame / 2
            for index in summary.joins.indices where summary.joins[index].cut == nil {
                let group = edges.filter { abs(($0.time - summary.joins[index].time).flicks) <= tolerance }
                let (past, before) = CutCheck.cutWords(beside: group, words: words)
                summary.joins[index].cut = past + before
            }
        }

        let levels = saved.problems.filter { $0.kind == .clippedWord }
        let combined = CutCheck.combine(problems: levels, notes: saved.notes.filter { $0.kind == .marginalJoin }, summary: summary)
        func at(_ problems: [CheckProblem], _ time: Double) -> [CheckProblem] { problems.filter { abs($0.start.seconds - time) < 0.01 } }

        lines.insert("Judged listen scorecard: \(summary.joins.count) joins, \(Set(saved.problems.map { Int(($0.start.seconds * 100).rounded()) }).count) flagged before, \(Set(combined.problems.map { Int(($0.start.seconds * 100).rounded()) }).count) after", at: 0)
        for verdict in ["real", "false", "unsure"] {
            let these = labels.filter { $0.verdict == verdict }
            let kept = these.filter { !at(combined.problems, $0.time).isEmpty }
            lines.append("  \(verdict) (\(these.count)): still flagged \(kept.count), dismissed \(these.count - kept.count)")
        }
        let unlabelled = Set(combined.problems.map { Int(($0.start.seconds * 100).rounded()) }).filter { time in !labels.contains { abs($0.time - Double(time) / 100) < 0.01 } }
        lines.append("  flagged after but not labelled: \(unlabelled.count)")
        for label in labels {
            let after = at(combined.problems, label.time)
            let notes = at(combined.notes, label.time).filter { $0.kind != .marginalJoin }
            let what = after.isEmpty ? "dismissed" : "FLAGGED"
            lines.append(String(format: "  %@ %8.3f %@ (%@): %@", label.verdict.padding(toLength: 6, withPad: " ", startingAt: 0), label.time, what, label.words, (after.isEmpty ? notes : after).map { "[\($0.kind.rawValue)] \($0.message.prefix(260))" }.joined(separator: " / ")))
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(labels.isEmpty)
    }

    /// Each speech file's words from the project's transcript cache, the
    /// newest for each file, in its own times.
    private func cachedWords(_ project: Project, folder: URL) throws -> [String: [CutAudit.Word]] {
        let cache = folder.appendingPathComponent(".tandem/cache/transcript", isDirectory: true)
        var newest: [String: (created: String, words: [TranscriptWord])] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: cache.path) {
            let entry = cache.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("entry.json")),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fingerprint = json["fingerprint"] as? String, let created = json["created"] as? String,
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: Data(contentsOf: entry.appendingPathComponent("transcript.json"))) else { continue }
            if newest[fingerprint].map({ $0.created < created }) ?? true { newest[fingerprint] = (created, transcript.words) }
        }
        var words: [String: [CutAudit.Word]] = [:]
        for item in project.media {
            guard let fingerprint = item.fingerprint, let found = newest[fingerprint] else { continue }
            words[item.id] = found.words.filter { $0.end > $0.start }.map { CutAudit.Word(text: $0.text, start: $0.start.seconds, end: $0.end.seconds) }
        }
        return words
    }
}
