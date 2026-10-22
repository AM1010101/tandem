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

    func testAProtectedFillerInARangeAskedForGoesWithIt() async throws {
        // "So. [um wrong idea.] Next." with the range 3-4 asked for and a
        // protect time on its "um": the range is the caller's choice, so it
        // cuts, and the "um" is counted as cut with it, not left in.
        let h = try harness(
            speech: [(2.0, 2.4), (3.0, 4.0), (5.0, 5.4)],
            words: [("So.", 2.0, 2.4), ("um", 3.0, 3.3), ("wrong", 3.35, 3.6), ("idea.", 3.65, 4.0), ("Next.", 5.0, 5.4)]
        )
        defer { h.close() }
        let plan = try await CutRequest(remove: [CutTarget(start: t(3), end: t(4))], fillers: true, protect: [t(3.2)]).run(on: h.service, context: h.context)
        XCTAssertEqual(plan.cuts.count, 1, "\(plan.cuts.map(\.asked))")
        let range = try XCTUnwrap(plan.cuts.first)
        XCTAssertEqual(range.status, .cut, range.reason ?? "")
        XCTAssertEqual(range.fillers, 1)
        let counts = try XCTUnwrap(plan.fillers)
        XCTAssertEqual(counts.found, 1)
        XCTAssertEqual(counts.cut, 1)
        XCTAssertEqual(counts.leftIn, [:])
        XCTAssertFalse(plan.readableText.contains("protected"), plan.readableText)
    }

    func testAFillerAFalseStartBringsBackIsCountedLeftIn() async throws {
        // "Okay. [as I said] uh we move." with "uh" running into "we": cut as
        // a false start, the end goes back to the pause before "uh", so the
        // "uh" stays, and the counts say so.
        let h = try harness(
            speech: [(14.0, 14.4), (14.9, 15.6), (16.0, 17.5)],
            words: [("Okay.", 14.0, 14.4), ("as", 14.9, 15.1), ("I", 15.12, 15.2), ("said", 15.25, 15.6), ("uh", 16.0, 16.35), ("we", 16.4, 16.7), ("move.", 16.75, 17.5)]
        )
        defer { h.close() }
        let plan = try await CutRequest(remove: [CutTarget(phrase: "as I said")], fillers: true, falseStart: true).run(on: h.service, context: h.context)
        let first = try XCTUnwrap(plan.cuts.first)
        XCTAssertEqual(first.fillers, 1)
        XCTAssertEqual(first.status, .cut, first.reason ?? "")
        XCTAssertEqual(first.broughtBack, "uh")
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.cut).end.seconds, 16.0)
        let counts = try XCTUnwrap(plan.fillers)
        XCTAssertEqual(counts.found, 1)
        XCTAssertEqual(counts.cut, 0)
        XCTAssertEqual(counts.leftIn, ["broughtBack": 1])
        XCTAssertEqual(counts.removed, .zero)
        XCTAssertTrue(plan.readableText.contains("1 left in (1 brought back"), plan.readableText)
    }

    func testAnAhRunningIntoTheNextWordIsLeftIn() async throws {
        // "Ah, I see." in one run of sound: "Ah" there is meant, and a cut
        // would clip "I".
        let h = try harness(speech: [(2.0, 3.0), (4.0, 4.4)], words: [("Ah,", 2.0, 2.2), ("I", 2.25, 2.4), ("see.", 2.45, 3.0), ("Right.", 4.0, 4.4)])
        defer { h.close() }
        let plan = try await CutRequest(remove: [], fillers: true).run(on: h.service, context: h.context)
        let ah = try stretch(at: 2.1, in: plan)
        XCTAssertEqual(ah.status, .kept)
        XCTAssertEqual(ah.problem, .fluent)
        XCTAssertEqual(plan.fillers?.leftIn, ["fluent": 1])
        XCTAssertTrue(plan.commands.isEmpty)
    }

    // MARK: - Joining and protecting

    private func word(_ text: String, _ start: Double, _ end: Double, _ clip: Clip) -> TranscriptTools.SpokenWord {
        TranscriptTools.SpokenWord(text: text, start: t(start), end: t(end), clipID: clip.id, mediaID: clip.mediaID ?? "", confidence: nil)
    }

    private func map(_ words: [TranscriptTools.SpokenWord], clips: [Clip], unknown: [TimeRange] = []) -> TranscriptTools.SpeechMap {
        let covered = clips.map(\.range).filter { range in !unknown.contains { $0.overlaps(range) } }
        return TranscriptTools.SpeechMap(words: words, covered: TimeRange.union(covered), unknown: unknown, missing: unknown.isEmpty ? [] : ["med_b"], clips: clips)
    }

    func testFillersOnlyJoinInOneRunOfTheTake() {
        // "um" at the end of clip A and "uh" at the start of clip C, 1.4 s
        // apart. In one clip, or two that carry straight on, they're one cut.
        let whole = Clip(id: "a", content: .media(mediaID: "med_a"), start: t(0), duration: t(10))
        let joined = TandemService.joining(
            TandemService.fillers(in: map([word("um", 4.5, 4.8, whole), word("uh", 6.2, 6.5, whole)], clips: [whole]), from: nil, to: nil, protect: []),
            to: [], in: map([word("um", 4.5, 4.8, whole), word("uh", 6.2, 6.5, whole)], clips: [whole])
        )
        XCTAssertEqual(joined.map(\.fillers), [2])
        let a = Clip(id: "a", content: .media(mediaID: "med_a"), start: t(0), duration: t(5))
        let on = Clip(id: "c", content: .media(mediaID: "med_a"), start: t(5), duration: t(5), sourceStart: t(5))
        let carried = map([word("um", 4.5, 4.8, a), word("uh", 5.2, 5.5, on)], clips: [a, on])
        XCTAssertEqual(TandemService.joining(TandemService.fillers(in: carried, from: nil, to: nil, protect: []), to: [], in: carried).map(\.fillers), [2])

        // With a clip nobody has a transcript for between them (someone
        // else talking, say), joining them would cut its speech unheard.
        let b = Clip(id: "b", content: .media(mediaID: "med_b"), start: t(5), duration: t(1))
        let c = Clip(id: "c", content: .media(mediaID: "med_a"), start: t(6), duration: t(4), sourceStart: t(6))
        let untranscribed = map([word("um", 4.5, 4.8, a), word("uh", 6.2, 6.5, c)], clips: [a, b, c], unknown: [TimeRange(start: t(5), end: t(6))])
        XCTAssertEqual(TandemService.joining(TandemService.fillers(in: untranscribed, from: nil, to: nil, protect: []), to: [], in: untranscribed).map(\.fillers), [1, 1])

        // Nor across a join an earlier cut made, from one part of the take to another.
        let later = Clip(id: "c", content: .media(mediaID: "med_a"), start: t(5), duration: t(5), sourceStart: t(9))
        let jumped = map([word("um", 4.5, 4.8, a), word("uh", 5.2, 5.5, later)], clips: [a, later])
        XCTAssertEqual(TandemService.joining(TandemService.fillers(in: jumped, from: nil, to: nil, protect: []), to: [], in: jumped).map(\.fillers), [1, 1])
    }

    func testAProtectTimeAfterTheLastFillerReachesTheEndOfItsClip() {
        // "So. [um]" at the end of a 5 s clip: the pause after "um" runs to
        // the clip's end, so a protect time in it leaves the "um" in.
        let clip = Clip(id: "a", content: .media(mediaID: "med_a"), start: t(0), duration: t(5))
        let speech = map([word("So.", 2.0, 2.4, clip), word("um", 3.0, 3.3, clip)], clips: [clip])
        XCTAssertEqual(TandemService.fillers(in: speech, from: nil, to: nil, protect: [t(3.8)]).first?.protected, t(3.8))
        XCTAssertNil(TandemService.fillers(in: speech, from: nil, to: nil, protect: [t(5.5)]).first?.protected)
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
