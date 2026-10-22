import XCTest
@testable import TandemMedia

/// `CutListen.compare`: what's heard across a join against what the take
/// keeps there.
final class CutListenTests: XCTestCase {
    /// Words a quarter of a second apart, from `start`, ending on the join
    /// at 10 or starting there as their place in `text` says ("|").
    private func words(_ text: String, join: Double = 10, gap: Double = 0.25) -> [CutListen.Word] {
        let parts = text.split(separator: " ").map(String.init)
        let at = parts.firstIndex(of: "|") ?? parts.count
        var out: [CutListen.Word] = []
        for (index, part) in parts.enumerated() where part != "|" {
            let start = index < at ? join - Double(at - index) * gap : join + Double(index - at - 1) * gap + 0.02
            out.append(CutListen.Word(text: part, start: start, end: start + gap * 0.8))
        }
        return out
    }

    func testAJoinHeardAsTheTakeSaysItHasNoFindings() {
        let join = CutListen.compare(said: words("a little bit | that happened because"), heard: words("A little bit, | that happened, because"), at: 10)
        XCTAssertEqual(join.findings, [])
        XCTAssertFalse(join.clipped)
        XCTAssertEqual(join.said, "a little bit | that happened because")
        XCTAssertEqual(join.heard, "A little bit, | that happened, because")
    }

    func testWordsMatchLoosely() {
        // Numbers, spoken forms, letters spelled out, case and punctuation.
        let join = CutListen.compare(said: words("I want to see | 15 of TS."), heard: words("i wanna see | fifteen of t. s."), at: 10)
        XCTAssertEqual(join.findings, [], "\(join.findings)")
    }

    func testAKeptWordHeardCutShortIsClipped() throws {
        let join = CutListen.compare(said: words("we can extract | the data"), heard: words("we can extra | the data"), at: 10)
        let finding = try XCTUnwrap(join.findings.first)
        XCTAssertEqual(finding.kind, .heardAs)
        XCTAssertEqual(finding.said, "extract")
        XCTAssertEqual(finding.heard, "extra")
        XCTAssertFalse(finding.slip)
        XCTAssertTrue(join.clipped)
    }

    func testAKeptWordNotHeardIsClippedUnlessItsAShortWord() throws {
        let gone = CutListen.compare(said: words("we can extract | the data"), heard: words("we can | the data"), at: 10)
        XCTAssertEqual(gone.findings.map(\.kind), [.notHeard])
        XCTAssertTrue(gone.clipped)
        // "the" is as likely the engine's slip: a note.
        let the = CutListen.compare(said: words("we can extract | the data"), heard: words("we can extract | data"), at: 10)
        XCTAssertEqual(the.findings.map(\.kind), [.notHeard])
        XCTAssertTrue(try XCTUnwrap(the.findings.first).slip)
        XCTAssertFalse(the.clipped)
    }

    func testAFragmentOfACutWordIsClipped() throws {
        // "a little bit [okay] that": the cut starts inside "okay", and the
        // start of it is heard as "oh".
        let join = CutListen.compare(
            said: words("a little bit | that that happened"), heard: words("a little bit oh | that that happened"), at: 10,
            cutPast: ["okay", "that"], cutBefore: ["know."]
        )
        let finding = try XCTUnwrap(join.findings.first)
        XCTAssertEqual(finding.kind, .extra)
        XCTAssertEqual(finding.heard, "oh")
        XCTAssertFalse(finding.slip, "it sounds like the cut \"okay\"")
        XCTAssertTrue(finding.why.contains("okay"), finding.why)
        // An "oh" that sounds like nothing cut is the engine's: a note.
        let other = CutListen.compare(said: words("a little bit | that that happened"), heard: words("a little bit oh | that that happened"), at: 10)
        XCTAssertTrue(try XCTUnwrap(other.findings.first).slip)
    }

    func testAnInflectionIsASlip() throws {
        let join = CutListen.compare(said: words("that | happened because"), heard: words("that | happen because"), at: 10)
        let finding = try XCTUnwrap(join.findings.first)
        XCTAssertEqual(finding.kind, .heardAs)
        XCTAssertTrue(finding.slip)
    }

    func testMismatchesAwayFromTheJoinArentFindings() {
        // The render's own edges cut words off: only what's near the join counts.
        let join = CutListen.compare(said: words("something in the recent | past and then on"), heard: words("thing in the recent | past and then"), at: 10)
        XCTAssertEqual(join.findings, [])
    }
}
