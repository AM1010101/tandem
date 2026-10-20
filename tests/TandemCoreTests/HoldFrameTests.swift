import XCTest
@testable import TandemCore

/// `holdFrame`: a one-frame flash in a screen recording (the preview
/// jumping as Mike clicked) used to take blade, blade, unlink, slip and
/// relink. Now it's one command.
final class HoldFrameTests: XCTestCase {
    func testHoldsTheFrameBeforeOverTheRangePictureOnly() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        let screen = f.clips("Screen")[0]
        let flash = TimeRange(start: t(10), duration: frame)
        let result = try c.run("Hold", .holdFrame(clipID: screen.id, range: flash))

        let pieces = c.clips("Screen")
        XCTAssertEqual(pieces.map(\.range), [
            TimeRange(start: t(0), end: flash.start),
            flash,
            TimeRange(start: flash.end, end: t(60))
        ])
        XCTAssertEqual(pieces[0].id, screen.id, "the piece before keeps the ID")
        let held = pieces[1]
        XCTAssertTrue(held.freezeFrame)
        XCTAssertEqual(held.sourceStart, screen.sourceTime(atTimelineTime: flash.start - frame), "the frame shown just before the flash")
        XCTAssertFalse(pieces[2].freezeFrame)
        XCTAssertEqual(pieces[2].sourceStart, screen.sourceTime(atTimelineTime: flash.end), "it plays on as it did after")
        XCTAssertEqual(result.createdIDs.first, held.id, "the held piece is the first ID back")

        XCTAssertEqual(c.clips("Voice").count, 1, "the sound isn't cut")
        XCTAssertEqual(c.clips("Camera").count, 1, "nor the camera")
        let group = c.clips("Voice")[0].linkGroup
        XCTAssertNotNil(group)
        XCTAssertEqual(Set(pieces.map(\.linkGroup)), [group], "every piece stays linked to the take")
        XCTAssertEqual(c.project.duration, f.project.duration, "nothing moves")
        assertValid(c.project)
    }

    func testLinkedPiecesStillMoveTogether() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        let screen = f.clips("Screen")[0]
        try c.run("Hold", .holdFrame(clipID: screen.id, range: TimeRange(start: t(10), duration: frame.scaled(by: 2))))
        let held = c.clips("Screen")[1]
        try c.run("Move", .moveClips(clipIDs: [held.id], delta: t(100)))
        XCTAssertEqual(c.clips("Screen").map(\.start), [t(100), t(110), t(110) + frame.scaled(by: 2)])
        XCTAssertEqual(c.clips("Voice")[0].start, t(100))
    }

    func testAtTheClipsStartTheHeldPieceKeepsTheID() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        let screen = f.clips("Screen")[0]
        try c.run("Hold", .holdFrame(clipID: screen.id, range: TimeRange(start: t(0), duration: frame)))
        let pieces = c.clips("Screen")
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].id, screen.id)
        XCTAssertTrue(pieces[0].freezeFrame)
        XCTAssertEqual(pieces[0].sourceStart, screen.sourceStart - frame, "the file's frame before the clip starts")
    }

    func testRefusesWhatItCantHold() throws {
        let (f, c) = try Fixture.edited()
        let screen = f.clips("Screen")[0]
        let voice = f.clips("Voice")[0]
        let frame = f.project.settings.frameRate.frameDuration
        XCTAssertThrowsError(try c.run("Sound", .holdFrame(clipID: voice.id, range: TimeRange(start: t(10), duration: frame))))
        XCTAssertThrowsError(try c.run("Past", .holdFrame(clipID: screen.id, range: TimeRange(start: t(59.99), duration: frame))))
        XCTAssertThrowsError(try c.run("Empty", .holdFrame(clipID: screen.id, range: TimeRange(start: t(10), duration: .zero))))
        try c.run("Lock", .updateTrack(trackID: f.track("Screen").id, patch: .object(["locked": .bool(true)])))
        XCTAssertThrowsError(try c.run("Locked", .holdFrame(clipID: screen.id, range: TimeRange(start: t(10), duration: frame))))
        XCTAssertEqual(c.clips("Screen").count, 1, "nothing changed")
    }
}
