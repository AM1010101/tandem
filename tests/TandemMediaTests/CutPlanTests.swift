import XCTest
@testable import TandemMedia

/// `CutPlanner` on made-up takes (`Take`, from SpeechEnergyTests): where it
/// puts each edge of a cut, and when it won't cut at all.
final class CutPlanTests: XCTestCase {
    private func placer(_ take: Take) -> CutPlacer {
        let energy = take.energy
        return CutPlacer(energy, levels: SpeechLevels(of: [energy]))
    }

    private func plan(
        _ take: Take, removing stretch: ClosedRange<Double>, cut: [ClosedRange<Double>] = [], kept: [ClosedRange<Double>] = [],
        keep: Double = 0.12, tightenFrom: Double = 0, falseStart: Bool? = nil
    ) -> CutPlan {
        CutPlanner.plan(placer(take), removing: stretch, cut: cut, kept: kept, keep: keep, tightenFrom: tightenFrom, falseStart: falseStart)
    }

    func testBothEdgesGoInThePausesEitherSide() throws {
        // "...that's it. [Um, sorry.] So the..." with 0.4 s pauses either side.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8)])
        let result = plan(take, removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8])
        XCTAssertTrue(result.cuts, "\(result)")
        let from = try XCTUnwrap(result.from), to = try XCTUnwrap(result.to)
        let before = try XCTUnwrap(result.startPause), after = try XCTUnwrap(result.endPause)
        // The pauses as the sound has them: the room's rumble splits off a
        // little of each, but they're in the silences between the words.
        assertInside(before, 11.0...11.4)
        assertInside(after, 11.9...12.3)
        XCTAssertGreaterThan(before.upperBound - before.lowerBound, 0.2)
        XCTAssertGreaterThan(after.upperBound - after.lowerBound, 0.2)
        XCTAssertTrue(before.contains(from) && after.contains(to))
        // A comma's 0.12 s, split as tighten does, but never under 30 ms
        // after the word before or 80 ms before the word after.
        XCTAssertEqual(result.keptBefore, 0.06, accuracy: 0.001)
        XCTAssertEqual(result.keptAfter, 0.08, accuracy: 0.001)
        XCTAssertEqual(from, before.lowerBound + 0.06, accuracy: 0.001)
        XCTAssertEqual(to, after.upperBound - 0.08, accuracy: 0.001)
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)
        XCTAssertGreaterThan(try XCTUnwrap(result.start?.margin), CutAudit.cleanFrom)
        XCTAssertGreaterThan(try XCTUnwrap(result.end?.margin), CutAudit.cleanFrom)
        XCTAssertFalse(result.falseStart)
        XCTAssertTrue(result.broughtBack.isEmpty)

        // After a sentence, 0.4 s: 0.2 either side.
        let sentence = plan(take, removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8], keep: 0.4)
        XCTAssertEqual(try XCTUnwrap(sentence.from), before.lowerBound + 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sentence.to), after.upperBound - 0.2, accuracy: 0.001)

        // Shorter pauses than the keep are kept, all but 30 ms of each by
        // the cut words.
        let snug = Take(length: 5, words: [(10.5, 11.0), (11.2, 11.9), (12.1, 12.8)])
        let whole = plan(snug, removing: 11.2...11.9, cut: [11.2...11.9], kept: [10.5...11.0, 12.1...12.8], keep: 0.6)
        XCTAssertTrue(whole.cuts, "\(whole)")
        let pauses = try XCTUnwrap(whole.startPause).upperBound - XCTUnwrap(whole.startPause).lowerBound
            + XCTUnwrap(whole.endPause).upperBound - XCTUnwrap(whole.endPause).lowerBound
        XCTAssertEqual(whole.keptBefore + whole.keptAfter, pauses - 0.06, accuracy: 0.001)
    }

    private func assertInside(_ pause: ClosedRange<Double>, _ gap: ClosedRange<Double>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(pause.lowerBound, gap.lowerBound - 0.006, "\(pause) in \(gap)", file: file, line: line)
        XCTAssertLessThanOrEqual(pause.upperBound, gap.upperBound + 0.006, "\(pause) in \(gap)", file: file, line: line)
    }

    func testPausesUnderTightensMinimumAreKeptAsTheyWere() throws {
        // 0.3 s pauses either side: shorter than tighten's 0.5 s, so the join
        // keeps one of them (0.3 s, less the 30 ms by the cut words), not the
        // sentence's 0.4 s or the mid-sentence 0.08.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.3, 11.9), (12.2, 12.8)])
        let result = plan(take, removing: 11.3...11.9, cut: [11.3...11.9], kept: [10.5...11.0, 12.2...12.8], keep: 0.08, tightenFrom: 0.5)
        XCTAssertTrue(result.cuts, "\(result)")
        XCTAssertEqual(result.keptBefore + result.keptAfter, 0.3, accuracy: 0.03)
    }

    func testAFillerInFluentSpeechIsLeftIn() {
        // "do that [because of] to keep": no pause either side of the filler.
        let take = Take(length: 5, words: [(10.5, 12.3), (13, 13.5)])
        let result = plan(
            take, removing: 11.3...11.7, cut: [11.3...11.5, 11.5...11.7],
            kept: [10.5...10.9, 10.9...11.3, 11.7...11.9, 11.9...12.3]
        )
        XCTAssertFalse(result.cuts)
        XCTAssertNil(result.from)
        XCTAssertEqual(result.problem, .fluent)
        XCTAssertNotNil(result.problemEdge)
        XCTAssertFalse(result.falseStart, "0.4 s isn't a long false start")

        // Without the transcript, the nearest pause is too far to be the
        // pause round these words.
        let unheard = plan(take, removing: 11.3...11.7)
        XCTAssertFalse(unheard.cuts)
        XCTAssertEqual(unheard.problem, .runsOn)
    }

    func testTheEdgeGoesInTheRealPauseWhenTheTranscriptIsLate() throws {
        // Two cut words with a 0.1 s pause between them, and the transcript
        // 0.2 s late on every word (#64: "processed" started 0.2 s before
        // SpeechAnalyzer said). The pause nearest the transcript's start is
        // the one between the two cut words; the real one is before them.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.6), (11.7, 11.9), (12.3, 12.8)])
        let late = 0.2
        let result = plan(
            take, removing: (11.4 + late)...(11.9 + late), cut: [(11.4 + late)...(11.6 + late), (11.7 + late)...(11.9 + late)],
            kept: [(10.5 + late)...(11.0 + late), (12.3 + late)...(12.8 + late)]
        )
        XCTAssertTrue(result.cuts, "\(result)")
        assertInside(try XCTUnwrap(result.startPause), 11.0...11.4)
        assertInside(try XCTUnwrap(result.endPause), 11.9...12.3)
        XCTAssertLessThan(try XCTUnwrap(result.from), 11.4, "not on the transcript's 11.6")
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)

        // From the sound alone, the late end still finds the real pause.
        // (The late start is in the pause between the two cut words, and
        // only the transcript can say a cut word is before it.)
        let unheard = plan(take, removing: (11.4 + late)...(11.9 + late))
        XCTAssertTrue(unheard.cuts, "\(unheard)")
        assertInside(try XCTUnwrap(unheard.endPause), 11.9...12.3)
    }

    func testALongFalseStartIsCutPauseToPauseAndARestartWordComesBack() throws {
        // "So the way [we do, the way we can, we] we do it": the false start
        // runs 2.2 s, and its last word runs straight into the restart.
        let take = Take(start: 9, length: 6, words: [(9.5, 9.8), (10.0, 10.3), (10.5, 10.8), (11.0, 11.3), (11.5, 11.7), (11.9, 12.7), (13.2, 13.6)])
        let cut: [ClosedRange<Double>] = [10.0...10.3, 10.5...10.8, 11.0...11.3, 11.5...11.7, 11.9...12.2]
        let kept: [ClosedRange<Double>] = [9.5...9.8, 12.2...12.7, 13.2...13.6]
        let result = plan(take, removing: 10.0...12.2, cut: cut, kept: kept)
        XCTAssertTrue(result.cuts, "\(result)")
        XCTAssertTrue(result.falseStart, "over 2 s: a long false start")
        assertInside(try XCTUnwrap(result.startPause), 9.8...10.0)
        assertInside(try XCTUnwrap(result.endPause), 11.7...11.9)
        XCTAssertEqual(result.broughtBack, [11.9...12.2], "the cut \"we\" comes back with the restart")
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)

        // Only as a false start: told it isn't, it's left in.
        let told = plan(take, removing: 10.0...12.2, cut: cut, kept: kept, falseStart: false)
        XCTAssertFalse(told.cuts)
        XCTAssertEqual(told.problem, .fluent)
        XCTAssertEqual(told.problemEdge, .end)

        // A short one is a false start only when asked.
        let rest = kept + cut.prefix(2)
        let short = plan(take, removing: 11.0...12.2, cut: Array(cut.suffix(3)), kept: rest)
        XCTAssertFalse(short.cuts, "1.2 s: put back rather than bring a word back")
        let asked = plan(take, removing: 11.0...12.2, cut: Array(cut.suffix(3)), kept: rest, falseStart: true)
        XCTAssertTrue(asked.cuts)
        XCTAssertEqual(asked.broughtBack, [11.9...12.2])
    }

    func testSeveralStretchesFromOneTake() throws {
        let take = Take(length: 8, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8), (13.3, 13.8), (14.2, 14.6), (15.1, 15.5)])
        let placer = placer(take)
        let words: [ClosedRange<Double>] = [10.5...11.0, 11.4...11.9, 12.3...12.8, 13.3...13.8, 14.2...14.6, 15.1...15.5]
        let plans = [11.4...11.9, 13.3...13.8].map { stretch in
            CutPlanner.plan(placer, removing: stretch, cut: words.filter { stretch.contains($0.lowerBound) }, kept: words.filter { !stretch.contains($0.lowerBound) }, keep: 0.12, falseStart: nil)
        }
        XCTAssertTrue(plans.allSatisfy(\.cuts), "\(plans)")
        XCTAssertLessThan(try XCTUnwrap(plans[0].to), try XCTUnwrap(plans[1].from))
        XCTAssertTrue(plans.allSatisfy { $0.start?.verdict == .clean && $0.end?.verdict == .clean })
    }

    func testAnEdgeThatWouldntBeCleanIsntCut() {
        // Snapped (to a frame, say) out of its pause and into the word:
        // judged clipped, so the stretch isn't cut.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8)])
        let result = CutPlanner.plan(
            placer(take), removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8], keep: 0.12, falseStart: nil,
            snap: { time, edge, _ in edge == .start ? 10.9 : time }
        )
        XCTAssertFalse(result.cuts)
        XCTAssertEqual(result.problem, .notClean)
        XCTAssertEqual(result.problemEdge, .start)
        XCTAssertEqual(result.start?.verdict, .clipped)
    }
}
