import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem cut --fillers`: every "um" and "uh" the transcript has, cut pause
/// to pause where there's a pause round it and left in where it runs into a
/// word that stays, as Mike likes it.
final class CutFillersTests: XCTestCase {
    /// The voice's sound (file time is timeline time to 30 s):
    /// "So [um] we go." with 0.6 s pauses round "um", "do um that." said
    /// without a break, "Right. [um, uh] next one.", "Okay. [as I said]
    /// [uh] we move." and "Then [erm] done.".
    static let speech: [(Double, Double)] = [
        (2.0, 2.4), (3.0, 3.4), (4.0, 4.8),
        (6.0, 7.0),
        (9.0, 9.5), (10.0, 10.3), (10.6, 10.9), (11.4, 12.2),
        (14.0, 14.4), (14.9, 15.6), (16.0, 16.3), (16.8, 17.5),
        (20.0, 20.4), (21.0, 21.4), (22.0, 22.4)
    ]
    static let words: [(String, Double, Double)] = [
        ("So", 2.0, 2.4), ("um", 3.0, 3.4), ("we", 4.0, 4.3), ("go.", 4.35, 4.8),
        ("do", 6.0, 6.3), ("um", 6.32, 6.62), ("that.", 6.65, 7.0),
        ("Right.", 9.0, 9.5), ("Um,", 10.0, 10.3), ("uh", 10.6, 10.9), ("next", 11.4, 11.8), ("one.", 11.85, 12.2),
        ("Okay.", 14.0, 14.4), ("as", 14.9, 15.1), ("I", 15.12, 15.2), ("said", 15.25, 15.6), ("uh", 16.0, 16.3), ("we", 16.8, 17.1), ("move.", 17.15, 17.5),
        ("Then", 20.0, 20.4), ("erm", 21.0, 21.4), ("done.", 22.0, 22.4)
    ]

    private func harness(speech: [(Double, Double)] = speech, words: [(String, Double, Double)] = words) throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try CutAPITests.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: speech)
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: words.map {
            TranscriptWord(text: $0.0, start: t($0.1), end: t($0.2))
        })
        return h
    }

    private func stretch(at time: Double, in result: CutResult, file: StaticString = #filePath, line: UInt = #line) throws -> CutStretch {
        try XCTUnwrap(result.cuts.first { $0.start.seconds <= time + 0.001 && time - 0.001 <= $0.end.seconds }, "nothing at \(time) in \(result.cuts.map(\.asked))", file: file, line: line)
    }

    func testFillersBetweenPausesAreCutAndOnesInRunningSpeechStay() async throws {
        let h = try harness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let revision = h.service.coordinator.revision
        let plan = try await CutRequest(remove: [], fillers: true).run(on: h.service, context: h.context)

        // "So [um] we": in the pauses either side, keeping a mid-sentence
        // join's 0.08 s, which with the least either side is 0.12 s, and
        // each edge on a frame rounds the kept pause up.
        let um = try stretch(at: 3.2, in: plan)
        XCTAssertEqual(um.status, .cut, um.reason ?? "")
        XCTAssertEqual(um.text, "um")
        XCTAssertEqual(um.fillers, 1)
        let cut = try XCTUnwrap(um.cut)
        XCTAssertTrue((2.4...3.0).contains(cut.start.seconds), "\(cut)")
        XCTAssertTrue((3.4...4.0).contains(cut.end.seconds), "\(cut)")
        let kept = try XCTUnwrap(um.keptBefore) + XCTUnwrap(um.keptAfter)
        XCTAssertGreaterThanOrEqual(kept.seconds, 0.12 - 0.001)
        XCTAssertLessThanOrEqual(kept.seconds, 0.12 + 2 / 30.0)
        XCTAssertEqual(um.startEdge?.verdict, .clean)
        XCTAssertEqual(um.endEdge?.verdict, .clean)

        // "do um that." in one breath: left in, fluent.
        let fluent = try stretch(at: 6.4, in: plan)
        XCTAssertEqual(fluent.status, .kept)
        XCTAssertEqual(fluent.problem, .fluent)
        XCTAssertNil(fluent.cut)

        // "Um, uh" side by side: one stretch, one cut, both words gone.
        let pair = try stretch(at: 10.1, in: plan)
        XCTAssertEqual(pair.text, "Um, uh")
        XCTAssertEqual(pair.fillers, 2)
        XCTAssertEqual(pair.status, .cut, pair.reason ?? "")
        XCTAssertEqual(pair.start, t(10.0))
        XCTAssertEqual(pair.end, t(10.9))
        XCTAssertFalse(plan.cuts.contains { $0.start.seconds > 10.5 && $0.start.seconds < 11 }, "no second cut for \"uh\"")

        let counts = try XCTUnwrap(plan.fillers)
        XCTAssertEqual(counts.found, 6)
        XCTAssertEqual(counts.cut, 5)
        XCTAssertEqual(counts.leftIn, ["fluent": 1])
        let fillerCuts = plan.cuts.filter { $0.fillers != nil && $0.status == .cut }.compactMap(\.cut)
        XCTAssertEqual(counts.removed, fillerCuts.reduce(.zero) { $0 + $1.duration })
        XCTAssertEqual(plan.commands.count, 1, "one cutRanges")

        let text = plan.readableText
        XCTAssertTrue(text.contains("Fillers: 6 found, 5 cut (removing "), text)
        XCTAssertTrue(text.contains("1 left in (1 in running speech)"), text)
        XCTAssertTrue(text.contains("  00:06.320-00:06.620  \"um\": no pause between it and \"do\""), text)

        // The dry run changed nothing; applied, it's one undo step, and
        // check --cuts finds nothing clipped at any of the joins.
        XCTAssertEqual(h.service.coordinator.project, before)
        XCTAssertEqual(h.service.coordinator.revision, revision)
        let applied = try await CutRequest(remove: [], fillers: true, apply: true).run(on: h.service, context: h.context)
        XCTAssertEqual(h.service.coordinator.revision, revision + 1)
        XCTAssertEqual(h.service.coordinator.project.duration, before.duration - applied.removed)
        let left = try h.service.transcript(id: nil, from: nil, to: nil).words.map(\.text)
        XCTAssertEqual(left.filter { TranscriptTools.filler($0) != nil }, ["um"], "only the fluent one is left: \(left)")
        let check = try await CheckRequest(from: t(0), to: t(25), cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(check.ok, "\(check.problems)")
        XCTAssertTrue(check.notes.isEmpty, "\(check.notes)")
        XCTAssertGreaterThan(check.cuts ?? 0, 0)
        XCTAssertNotNil(h.service.coordinator.undo())
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    func testAFillerNextToAPhraseBeingCutIsOneStretch() async throws {
        let h = try harness()
        defer { h.close() }
        let plan = try await CutRequest(remove: [CutTarget(phrase: "as I said")], fillers: true).run(on: h.service, context: h.context)
        // The phrase comes first, as asked, with the "uh" after it in it.
        let first = try XCTUnwrap(plan.cuts.first)
        XCTAssertEqual(first.text, "as I said uh")
        XCTAssertEqual(first.asked, "as I said + uh")
        XCTAssertEqual(first.fillers, 1)
        XCTAssertEqual(first.status, .cut, first.reason ?? "")
        XCTAssertEqual(first.start, t(14.9))
        XCTAssertEqual(first.end, t(16.3))
        let cut = try XCTUnwrap(first.cut)
        XCTAssertTrue((14.4...14.9).contains(cut.start.seconds), "\(cut)")
        XCTAssertTrue((16.3...16.8).contains(cut.end.seconds), "\(cut)")
        XCTAssertEqual(plan.cuts.filter { $0.start.seconds > 15.5 && $0.start.seconds < 16.5 }.count, 0, "the \"uh\" has no stretch of its own")
    }

    func testFromToAndProtect() async throws {
        let h = try harness()
        defer { h.close() }
        let bounded = try await CutRequest(remove: [], fillers: true, from: t(5), to: t(19)).run(on: h.service, context: h.context)
        XCTAssertEqual(bounded.fillers?.found, 4, "\(bounded.cuts.map(\.text))")
        XCTAssertFalse(bounded.cuts.contains { $0.start < t(5) || $0.end > t(19) })

        // A protect time in the pause before "erm" leaves it in.
        let kept = try await CutRequest(remove: [], fillers: true, from: t(19), protect: [t(20.7)]).run(on: h.service, context: h.context)
        let erm = try stretch(at: 21.2, in: kept)
        XCTAssertEqual(erm.status, .kept)
        XCTAssertTrue(try XCTUnwrap(erm.reason).contains("protect"), erm.reason ?? "")
        XCTAssertEqual(kept.fillers?.leftIn, ["protected": 1])
        XCTAssertTrue(kept.commands.isEmpty)
        let free = try await CutRequest(remove: [], fillers: true, from: t(19)).run(on: h.service, context: h.context)
        XCTAssertEqual(try stretch(at: 21.2, in: free).status, .cut)
    }

    func testTheJoinKeepsWhatTightenWouldLeaveWithoutTheFiller() async throws {
        // "So [um] we go." cut down to "So we go." leaves the pause tighten
        // --mike leaves where "So ... we go." has no "um" at all.
        let h = try harness()
        defer { h.close() }
        let plan = try await CutRequest(remove: [], fillers: true, to: t(5)).run(on: h.service, context: h.context)
        let um = try stretch(at: 3.2, in: plan)
        let cutKept = try XCTUnwrap(um.keptBefore) + XCTUnwrap(um.keptAfter)

        let quiet = try harness(speech: [(2.0, 2.4), (4.0, 4.8)], words: [("So", 2.0, 2.4), ("we", 4.0, 4.3), ("go.", 4.35, 4.8)])
        defer { quiet.close() }
        let tighten = try await quiet.service.tighten(TightenRequest(mike: true, to: t(5)), context: quiet.context)
        let pause = try XCTUnwrap(tighten.cuts.first, "\(tighten.skipped)")
        let tightenKept = (pause.cut.start.seconds - 2.4) + (4.0 - pause.cut.end.seconds)
        print("cut --fillers keeps \(cutKept.seconds) s at \"So | we\"; tighten --mike without the um keeps \(tightenKept) s")
        XCTAssertEqual(cutKept.seconds, tightenKept, accuracy: 0.034, "cut keeps \(cutKept), tighten \(tightenKept)")
    }

    func testAFilledPauseUnderHalfASecondEachSideIsTightenedAsOnePause() async throws {
        // "So, [um] we go." with 0.3 s either side of the "um": tighten
        // would hear "So, ... we" as one 0.9 s pause and keep a comma's
        // 0.12 s (0.06 / 0.08, on frames), so cutting the "um" does the same.
        let h = try harness(speech: [(2.0, 2.4), (2.7, 3.0), (3.3, 4.1)], words: [("So,", 2.0, 2.4), ("um", 2.7, 3.0), ("we", 3.3, 3.6), ("go.", 3.65, 4.1)])
        defer { h.close() }
        let plan = try await CutRequest(remove: [], fillers: true).run(on: h.service, context: h.context)
        let um = try stretch(at: 2.8, in: plan)
        XCTAssertEqual(um.status, .cut, um.reason ?? "")
        let cutKept = try XCTUnwrap(um.keptBefore) + XCTUnwrap(um.keptAfter)

        let quiet = try harness(speech: [(2.0, 2.4), (3.3, 4.1)], words: [("So,", 2.0, 2.4), ("we", 3.3, 3.6), ("go.", 3.65, 4.1)])
        defer { quiet.close() }
        let tighten = try await quiet.service.tighten(TightenRequest(mike: true), context: quiet.context)
        let pause = try XCTUnwrap(tighten.cuts.first, "\(tighten.skipped)")
        let tightenKept = (pause.cut.start.seconds - 2.4) + (3.3 - pause.cut.end.seconds)
        print("cut --fillers keeps \(cutKept.seconds) s at \"So, | we\"; tighten --mike without the um keeps \(tightenKept) s")
        XCTAssertEqual(cutKept.seconds, tightenKept, accuracy: 0.034)
        XCTAssertLessThan(cutKept.seconds, 0.2)
    }

    func testFillersAloneNeedNoPhraseAndTheRequestReadsThem() throws {
        let request = try ServiceJSON.decodeRequest(CutRequest.self, from: Data(#"{"fillers": true, "from": "0:05", "to": 19, "protect": ["0:20.7"]}"#.utf8))
        XCTAssertEqual(request.remove, [])
        XCTAssertEqual(request.fillers, true)
        XCTAssertEqual(request.from, t(5))
        XCTAssertEqual(request.to, t(19))
        XCTAssertEqual(request.protect, [t(20.7)])
    }

    func testNoFillersSaysSo() async throws {
        let h = try harness(speech: [(2.0, 2.4)], words: [("So.", 2.0, 2.4)])
        defer { h.close() }
        let plan = try await CutRequest(remove: [], fillers: true).run(on: h.service, context: h.context)
        XCTAssertEqual(plan.fillers?.found, 0)
        XCTAssertTrue(plan.commands.isEmpty)
        XCTAssertTrue(plan.readableText.hasPrefix("No fillers to cut"), plan.readableText)
    }
}
