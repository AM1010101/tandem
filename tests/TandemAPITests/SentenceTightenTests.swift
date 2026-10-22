import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// Tightening by what a pause follows: Mike's 0.4 s between sentences, his
/// thinking pauses closed right up, breaths left alone, and joins widened
/// back out where the take has the silence for it.
final class SentenceTightenTests: XCTestCase {
    func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: t(start), end: t(end))
    }

    func testWhatAPauseFollows() {
        XCTAssertEqual(TranscriptTools.pauseKind(after: "talk about decision models."), .sentence)
        XCTAssertEqual(TranscriptTools.pauseKind(after: "is it?"), .sentence)
        XCTAssertEqual(TranscriptTools.pauseKind(after: "wow!\""), .sentence, "a closing quote doesn't hide the full stop")
        XCTAssertEqual(TranscriptTools.pauseKind(after: "and then..."), .sentence)
        XCTAssertEqual(TranscriptTools.pauseKind(after: "Well,"), .comma)
        XCTAssertEqual(TranscriptTools.pauseKind(after: "three things:"), .comma)
        XCTAssertEqual(TranscriptTools.pauseKind(after: "help you choose"), .mid)
    }

    /// The fixture's pauses: 1.4 s after "models.", 0.7 s after "choose"
    /// (mid-sentence), 20 s after "matter." and 0.6 s after "section.".
    func testSentencesKeepTheirPauseAndThinkingPausesClose() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(sentence: 0.4, mid: 0.08), context: h.context)
        XCTAssertNil(plan.applied)
        XCTAssertEqual(plan.cuts.map(\.kind), [.sentence, .mid, .sentence, .sentence])
        XCTAssertEqual(plan.cuts.map(\.keep), [t(0.4), t(0.08), t(0.4), t(0.4)])
        XCTAssertEqual(plan.cuts[0].cut, TimeRange(start: t(3.8), end: t(4.8)))
        XCTAssertEqual(plan.sentence, t(0.4))
        XCTAssertEqual(plan.mid, t(0.08))
        XCTAssertNil(plan.comma)

        _ = try await h.service.tighten(TightenRequest(sentence: 0.4, mid: 0.08, apply: true), context: h.context)
        let after = try h.service.pauses(minimum: t(0.05), from: nil, to: nil).pauses
        let models = try XCTUnwrap(after.first { $0.before.hasSuffix("models.") && $0.after.hasPrefix("They") })
        XCTAssertEqual(models.duration.seconds, 0.4, accuracy: 0.034)
        let choose = try XCTUnwrap(after.first { $0.before.hasSuffix("choose") })
        XCTAssertLessThanOrEqual(choose.duration.seconds, 0.08 + 0.034)
        XCTAssertGreaterThanOrEqual(choose.duration.seconds, 0.08)
    }

    /// A kind without a keep is left as it is.
    func testOnlyTheKindsAskedForChange() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(mid: 0.08), context: h.context)
        XCTAssertEqual(plan.cuts.map(\.kind), [.mid])
    }

    func testCommasBreathsAndProtectedPauses() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            word("Well,", 1.0, 1.4),
            word("this", 2.1, 2.4),       // 0.7 s after a comma: closed to the comma keep
            word("is", 2.45, 2.6),
            word("fine.", 2.65, 3.0),
            word("Next", 4.0, 4.3),       // 1 s after a sentence, but protected
            word("one,", 4.35, 4.6),
            word("please", 4.9, 5.2),     // 0.3 s after a comma: a breath, left
            word("now", 5.6, 5.9),        // 0.4 s mid-sentence: under midMin, left
            word("thanks.", 6.7, 7.0)     // 0.8 s mid-sentence: closed
        ])
        let plan = try await h.service.tighten(TightenRequest(mike: true, protect: [t(3.5)]), context: h.context)
        XCTAssertEqual(plan.cuts.map(\.kind), [.comma, .mid])
        XCTAssertEqual(plan.cuts.map(\.keep), [t(0.12), t(0.08)])
        XCTAssertEqual(plan.cuts.map(\.pause.start), [t(1.4), t(5.9)])
        XCTAssertEqual(plan.protected.map(\.start), [t(3.0)])

        // The comma falls back to the mid-sentence keep when it has none.
        let fallback = try await h.service.tighten(TightenRequest(sentence: 0.4, mid: 0.08), context: h.context)
        XCTAssertEqual(fallback.cuts.filter { $0.kind == .comma }.map(\.keep), [t(0.08)])
        XCTAssertEqual(fallback.cuts.filter { $0.kind == .sentence }.map(\.pause.start), [t(3.0)], "unprotected, the sentence pause is tightened")

        // A shorter midMin reaches the breaths too.
        let closer = try await h.service.tighten(TightenRequest(sentence: 0.4, mid: 0.08, midMin: 0.25), context: h.context)
        XCTAssertEqual(closer.cuts.map(\.pause.start), [t(1.4), t(3.0), t(4.6), t(5.2), t(5.9)])
    }

    func testTheMikePresetAndItsOverrides() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let mike = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertEqual(mike.sentence, t(0.4))
        XCTAssertEqual(mike.comma, t(0.12))
        XCTAssertEqual(mike.mid, t(0.08))
        XCTAssertEqual(mike.minimum, t(0.5))
        XCTAssertEqual(mike.midMinimum, t(0.5))
        let looser = try await h.service.tighten(TightenRequest(sentence: 0.5, mike: true), context: h.context)
        XCTAssertEqual(looser.sentence, t(0.5))
        XCTAssertEqual(looser.mid, t(0.08))
        XCTAssertTrue(looser.readableText.contains("0.500s after a sentence"), looser.readableText)
    }

    func testPlainMinAndKeepStillWork() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(min: 0.6, keep: 0.15), context: h.context)
        XCTAssertEqual(plan.cuts.count, 4)
        XCTAssertNil(plan.sentence)
        XCTAssertTrue(plan.cuts.allSatisfy { $0.keep == t(0.15) })
        let protected = try await h.service.tighten(TightenRequest(min: 0.6, keep: 0.15, protect: [t(6.5)]), context: h.context)
        XCTAssertEqual(protected.cuts.count, 3)
        XCTAssertEqual(protected.protected.map(\.start), [t(6.3)])
        await assertServiceErrorAsync(.badRequest) { _ = try await h.service.tighten(TightenRequest(keep: 0.15, sentence: 0.4), context: h.context) }
        await assertServiceErrorAsync(.badRequest) { _ = try await h.service.tighten(TightenRequest(sentence: -1), context: h.context) }
    }

    // MARK: - Widening

    /// The fixture's cut takes file 30-32 out between the two pieces. Here
    /// "section." ends at file 29.85 and "Now" starts at 32.05, so the join
    /// leaves 0.2 s between sentences, and both sides have silence to give.
    func joinTranscript(_ middle: [TranscriptWord] = []) -> Transcript {
        Transcript(language: "en", engine: "fake", words: [
            word("Second", 29.0, 29.4),
            word("section.", 29.45, 29.85)
        ] + middle + [
            word("Now", 32.05, 32.4),
            word("let's", 32.45, 32.7),
            word("look.", 32.75, 33.0)
        ])
    }

    func testAJoinTooTightForASentenceWidensFromBothSides() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = joinTranscript()
        let without = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertTrue(without.widened.isEmpty, "widening is opt-in")

        let before = h.service.coordinator.project
        let plan = try await h.service.tighten(TightenRequest(mike: true, widen: true), context: h.context)
        XCTAssertEqual(h.service.coordinator.project, before, "a dry run changes nothing")
        XCTAssertEqual(plan.widened.count, 1)
        let widen = try XCTUnwrap(plan.widened.first)
        XCTAssertEqual(widen.at, t(30))
        XCTAssertEqual(widen.clipID, "clip_voc1")
        XCTAssertEqual(widen.nextClipID, "clip_voc2")
        XCTAssertEqual(widen.kind, .sentence)
        XCTAssertEqual(widen.tail, Time.frames(3, at: .fps30))
        XCTAssertEqual(widen.head, Time.frames(3, at: .fps30))
        XCTAssertEqual(plan.added, Time.frames(6, at: .fps30))
        XCTAssertEqual(plan.durationAfter, plan.durationBefore + plan.added - plan.removed)

        let applied = try await h.service.tighten(TightenRequest(mike: true, widen: true, apply: true), context: h.context)
        XCTAssertNotNil(applied.applied)
        let pause = try XCTUnwrap(try h.service.pauses(minimum: t(0.1), from: nil, to: nil).pauses.first { $0.before.hasSuffix("section.") })
        XCTAssertEqual(pause.duration.seconds, 0.4, accuracy: 0.001)
        // The camera and screen stay with the voice.
        let project = h.service.coordinator.project
        let voice = try XCTUnwrap(project.track("trk_voice")).clips
        for trackID in ["trk_camera", "trk_screen"] {
            XCTAssertEqual(try XCTUnwrap(project.track(trackID)).clips.map(\.range), voice.map(\.range), trackID)
        }
        XCTAssertEqual(voice[1].sourceStart.seconds, 31.9, accuracy: 0.001)
        _ = try h.service.undo(expectedRevision: nil)
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    /// Words the cut took out stay out: only silence between words comes back.
    func testWideningNeverBringsBackSpeech() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = joinTranscript([word("Um,", 30.05, 30.3), word("wait.", 30.4, 30.8)])
        let plan = try await h.service.tighten(TightenRequest(mike: true, widen: true, apply: true), context: h.context)
        let widen = try XCTUnwrap(plan.widened.first)
        XCTAssertEqual(widen.tail, .zero, "\"Um,\" starts 0.05 s after the first piece ends")
        XCTAssertEqual(widen.head, Time.frames(6, at: .fps30), "the silence after \"wait.\" gives it all")
        let text = try h.service.transcript(id: nil, from: nil, to: nil).words.map(\.text).joined(separator: " ")
        XCTAssertEqual(text, "Second section. Now let's look.")
    }

    func testAJoinWithNoSilenceEitherSideIsLeft() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            word("Second", 29.0, 29.4),
            word("section.", 29.45, 29.85),
            word("Um,", 29.95, 30.3),     // straddles the first piece's end
            word("wait.", 31.5, 32.02),   // straddles the second piece's start
            word("Now", 32.05, 32.4)
        ])
        let plan = try await h.service.tighten(TightenRequest(mike: true, widen: true), context: h.context)
        XCTAssertTrue(plan.widened.isEmpty, "\(plan.widened)")
    }

    func testAProtectedJoinIsntWidened() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = joinTranscript()
        let plan = try await h.service.tighten(TightenRequest(mike: true, protect: [t(30)], widen: true), context: h.context)
        XCTAssertTrue(plan.widened.isEmpty)
    }

    func testTheRequestReadsFromJSON() throws {
        let json = #"{"sentence": 0.4, "comma": "0:00.120", "mid": 0.08, "midMin": 0.5, "protect": [12.5, "1:02.250"], "widen": true, "mike": true}"#
        let request = try JSONDecoder().decode(TightenRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.sentence, 0.4)
        XCTAssertEqual(request.comma ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertEqual(request.midMin, 0.5)
        XCTAssertEqual(request.protect, [t(12.5), t(62.25)])
        XCTAssertEqual(request.widen, true)
        XCTAssertEqual(request.mike, true)
    }
}
