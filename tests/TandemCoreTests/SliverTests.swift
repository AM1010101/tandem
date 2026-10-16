import XCTest
@testable import TandemCore

/// Rounding in agents' batches leaves clips overlapping by a hair (issue
/// #44). Under a millisecond counts as touching: the later clip starts where
/// the earlier one ends, and the edit goes through.
final class SliverOverlapTests: XCTestCase {
    func testPlacingHalfAMillisecondIntoTheLastClipSnapsTheNewClipToItsEnd() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(24.9995), sourceStart: t(2), duration: t(3)))
        let clips = c.clips("B-roll")
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].end, t(25))
        XCTAssertEqual(clips[1].start, t(25))
        XCTAssertEqual(clips[1].sourceStart, t(2.0005))
        XCTAssertEqual(clips[1].end, t(27.9995))
        assertValid(c.project)
    }

    func testANewClipEndingJustInsideTheNextOneMovesTheNextOnesStart() throws {
        let (f, c) = try Fixture.edited()
        let next = f.clips("B-roll")[0]
        let slug = Clip(id: "clip_slug", content: .solid(color: .black), start: t(18), duration: t(2.0004))
        try c.run("Insert", .insertClip(trackID: f.track("B-roll").id, clip: slug))
        let clips = c.clips("B-roll")
        XCTAssertEqual(clips.map(\.id), ["clip_slug", next.id])
        XCTAssertEqual(clips[0].end, t(20.0004))
        XCTAssertEqual(clips[1].start, t(20.0004))
        XCTAssertEqual(clips[1].end, next.end)
        XCTAssertEqual(clips[1].sourceStart, next.sourceStart + t(0.0004))
        assertValid(c.project)
    }

    func testARealOverlapIsStillAnError() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(24.998), duration: t(3)))) { error in
            guard case EditError.overlap = error else { return XCTFail("expected an overlap, got \(error)") }
        }
    }

    func testAShortClipInsideAnotherIsStillAnOverlap() throws {
        let (f, c) = try Fixture.edited()
        let tiny = Clip(id: "clip_tiny", content: .solid(color: .black), start: t(21), duration: t(0.0005))
        XCTAssertThrowsError(try c.run("Insert", .insertClip(trackID: f.track("B-roll").id, clip: tiny)))
    }

    func testTrimmingATailJustPastTheNextClipGoesThrough() throws {
        let (f, c) = try Fixture.edited()
        let broll = f.clips("B-roll")[0]
        let slug = Clip(id: "clip_slug", content: .solid(color: .black), start: t(25), duration: t(2))
        try c.run("Insert", .insertClip(trackID: f.track("B-roll").id, clip: slug))
        try c.run("Trim", .trim(clipID: broll.id, edge: .end, to: t(25.0003)))
        let clips = c.clips("B-roll")
        XCTAssertEqual(clips[0].end, t(25.0003))
        XCTAssertEqual(clips[1].start, t(25.0003))
        XCTAssertEqual(clips[1].end, t(27))
        assertValid(c.project)
    }

    func testMovingAClipAHairOntoItsNeighbourGoesThrough() throws {
        let (f, c) = try Fixture.edited()
        let slug = Clip(id: "clip_slug", content: .solid(color: .black), start: t(26), duration: t(2))
        try c.run("Insert", .insertClip(trackID: f.track("B-roll").id, clip: slug))
        try c.run("Move", .moveClips(clipIDs: ["clip_slug"], delta: t(-1.0002)))
        let clips = c.clips("B-roll")
        XCTAssertEqual(clips[0].end, t(25))
        XCTAssertEqual(clips[1].start, t(25))
        XCTAssertEqual(clips[1].end, t(26.9998))
        assertValid(c.project)
    }
}
