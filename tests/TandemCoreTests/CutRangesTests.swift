import XCTest
@testable import TandemCore

/// `cutRanges` takes every range in the timeline's times before the command,
/// so agents don't have to sort ripple deletes latest first themselves.
final class CutRangesTests: XCTestCase {
    func testRangesAreInTheTimesBeforeTheCommandWhateverTheirOrder() throws {
        let (_, c) = try Fixture.edited()
        // Earliest first: applied in this order as ripple deletes, the second
        // range would land 2 s too late.
        try c.run("Cut", .cutRanges(ranges: [
            TimeRange(start: t(10), end: t(12)),
            TimeRange(start: t(30), end: t(31)),
            TimeRange(start: t(20), end: t(20.5))
        ]))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).map(\.range), [
                TimeRange(start: t(0), end: t(10)),
                TimeRange(start: t(10), end: t(18)),
                TimeRange(start: t(18), end: t(27.5)),
                TimeRange(start: t(27.5), end: t(56.5))
            ], name)
        }
        XCTAssertEqual(c.clips("Camera").map(\.sourceStart), [t(0), t(12), t(20.5), t(31)])
        XCTAssertEqual(c.project.markers[0].time, t(27.5), "the marker at 30 is the start of the 30-31 cut")
        XCTAssertEqual(c.project.duration, t(56.5))
        assertValid(c.project)
    }

    func testOverlappingAndTouchingRangesAreCutOnce() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [
            TimeRange(start: t(10), end: t(12)),
            TimeRange(start: t(11), end: t(13)),
            TimeRange(start: t(13), end: t(14))
        ]))
        XCTAssertEqual(c.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(56))])
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(14))
        assertValid(c.project)
    }

    func testTrackIDsLimitTheCut() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(30), end: t(32)), TimeRange(start: t(40), end: t(41))], trackIDs: ["B-roll", "Music"]))
        XCTAssertEqual(c.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(60))], "the take isn't cut")
        XCTAssertEqual(c.clips("Music").map(\.range), [
            TimeRange(start: t(0), end: t(30)), TimeRange(start: t(30), end: t(38)), TimeRange(start: t(38), end: t(57))
        ])
        XCTAssertEqual(f.clips("B-roll").map(\.range), c.clips("B-roll").map(\.range))
    }

    func testOneUndoPutsEveryRangeBack() throws {
        let (_, c) = try Fixture.edited()
        let before = c.project
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(5), end: t(6)), TimeRange(start: t(40), end: t(42))]))
        XCTAssertEqual(c.project.duration, t(57))
        _ = c.undo()
        XCTAssertEqual(c.project, before)
    }

    func testBadRangesAreRefused() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Cut", .cutRanges(ranges: [])))
        XCTAssertThrowsError(try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(4), end: t(4))])))
        XCTAssertThrowsError(try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(-1), end: t(2))])))
    }
}
