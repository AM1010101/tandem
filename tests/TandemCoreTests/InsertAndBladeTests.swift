import XCTest
@testable import TandemCore

/// `blade` with `clipIDs` follows the pieces a batch cuts from a clip, and
/// says where the clip is when none of it is at the time (#51).
final class BladeClipIDsTests: XCTestCase {
    func testASecondBladeOfTheSameClipCutsThePieceThatCoversTheTime() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cuts", .blade(at: t(10), clipIDs: [camera]), .blade(at: t(20), clipIDs: [camera]))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).map(\.range), [
                TimeRange(start: t(0), end: t(10)),
                TimeRange(start: t(10), end: t(20)),
                TimeRange(start: t(20), end: t(60))
            ], name)
        }
        XCTAssertEqual(c.clips("Camera")[0].id, camera, "the left piece keeps the ID")
        XCTAssertEqual(c.clips("Music").count, 1, "unlinked tracks aren't cut")
        assertValid(c.project)
    }

    func testItFollowsPiecesThroughSeveralCuts() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cuts", .blade(at: t(10), clipIDs: [camera]), .blade(at: t(30), clipIDs: [camera]), .blade(at: t(20), clipIDs: [camera]), .blade(at: t(40), clipIDs: [camera]))
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), t(10), t(20), t(30), t(40)])
        XCTAssertEqual(c.clips("Voice").map(\.start), [t(0), t(10), t(20), t(30), t(40)])
    }

    func testATimeOutsideTheClipFailsSayingWhereItIs() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        XCTAssertThrowsError(try c.run("Cut again", .blade(at: t(20), clipIDs: [camera]))) { error in
            let message = (error as? EditError)?.description ?? ""
            XCTAssertTrue(message.contains(camera), message)
            XCTAssertTrue(message.contains("00:00.000") && message.contains("00:10.000"), message)
        }
        XCTAssertThrowsError(try c.run("Past the end", .blade(at: t(90), clipIDs: [camera])))
        XCTAssertEqual(c.clips("Camera").count, 2, "nothing changed")
    }

    func testAPieceCutInTheSameBatchIsNamedInTheError() throws {
        let (f, c) = try Fixture.edited()
        let broll = f.clips("B-roll")[0].id
        XCTAssertThrowsError(try c.run("Cuts", .blade(at: t(22), clipIDs: [broll]), .blade(at: t(27), clipIDs: [broll]))) { error in
            let message = (error as? EditError)?.description ?? ""
            XCTAssertTrue(message.contains("00:20.000") && message.contains("00:25.000"), message)
        }
    }

    func testAnExistingCutIsNoError() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        let result = try c.run("Same cut", .blade(at: t(10), clipIDs: [camera]))
        XCTAssertEqual(result.warnings, ["Nothing to cut at 00:10.000."])
    }
}

/// `placeMedia` with a `speed` (#53).
final class PlaceAtSpeedTests: XCTestCase {
    func testSpeedPlacesAllTheMediaShorter() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(40), speed: 2))
        let clip = try XCTUnwrap(c.clips("B-roll").last)
        XCTAssertEqual(clip.speed, 2)
        XCTAssertEqual(clip.range, TimeRange(start: t(40), end: t(45)), "the 10 s file plays in 5 s")
        XCTAssertEqual(clip.sourceEnd, t(10))
        assertValid(c.project)
    }

    func testDurationIsTheTimelineLength() throws {
        let (_, c) = try Fixture.edited()
        // A 9.6 s shot at 1.5x fills a 6.4 s gap.
        try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(30), sourceStart: t(0.4), duration: t(6.4), speed: 1.5))
        let clip = try XCTUnwrap(c.clips("B-roll").last)
        XCTAssertEqual(clip.range, TimeRange(start: t(30), end: t(36.4)))
        XCTAssertEqual(clip.sourceStart, t(0.4))
        XCTAssertEqual(clip.sourceEnd, t(10))
    }

    func testATakeAndItsSoundAllChangeSpeed() throws {
        var fixture = Fixture()
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Place", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, speed: 1.5))
        fixture.project = c.project
        let clips = ["Camera", "Screen", "Voice"].map { c.clips($0)[0] }
        for clip in clips {
            XCTAssertEqual(clip.speed, 1.5)
            XCTAssertEqual(clip.range, TimeRange(start: .zero, end: t(40)), "60 s of the take at 1.5x")
        }
        XCTAssertEqual(Set(clips.map(\.linkGroup)).count, 1)
        XCTAssertEqual(clips[2].audio?.normalizeTo, -20, "the sound keeps its levels")
        assertValid(c.project)
    }

    func testMoreThanTheFileHoldsFails() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(30), duration: t(6), speed: 2)))
        XCTAssertThrowsError(try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(30), speed: 0)))
        XCTAssertThrowsError(try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(30), speed: 101)))
    }

    func testSpeedRoundTripsThroughJSON() throws {
        let json = #"{"placeMedia": {"mediaIDs": ["med_broll"], "at": 30, "duration": 6.4, "speed": 1.5}}"#
        let command = try JSONDecoder().decode(EditCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command, .placeMedia(mediaIDs: ["med_broll"], at: t(30), duration: t(6.4), speed: 1.5))
    }
}

/// Inserting right at, or a hair off, a clip boundary (#29).
final class InsertAtABoundaryTests: XCTestCase {
    /// The take cut at 10.0003125 s, which `tandem timeline` shows as
    /// 00:10.000.
    func cutJustAfterTen() throws -> (Fixture, ProjectCoordinator, Time) {
        let (f, c) = try Fixture.edited()
        let cut = Time(seconds: 10.0003125)
        try c.run("Cut", .blade(at: cut, clipIDs: [f.clips("Camera")[0].id]))
        return (f, c, cut)
    }

    func testAnInsertAtAClipsStartMovesTheWholeClip() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10), clipIDs: [f.clips("Camera")[0].id]))
        try c.run("Insert", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: t(10), sourceStart: t(0.5), duration: t(5), mode: .insert))
        XCTAssertEqual(c.clips("Camera").map(\.range), [
            TimeRange(start: t(0), end: t(10)),
            TimeRange(start: t(10), end: t(15)),
            TimeRange(start: t(15), end: t(65))
        ])
    }

    func testAnInsertWithinHalfAFrameOfACutGoesOnTheCut() throws {
        let (_, c, cut) = try cutJustAfterTen()
        let result = try c.run("Insert", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: t(10), sourceStart: t(0.5), duration: t(5), mode: .insert))
        for name in ["Camera", "Screen", "Voice"] {
            XCTAssertEqual(c.clips(name).map(\.range), [
                TimeRange(start: t(0), end: cut),
                TimeRange(start: cut, end: cut + t(5)),
                TimeRange(start: cut + t(5), end: t(65))
            ], name)
        }
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        assertValid(c.project)
    }

    func testInsertTimeAndInsertClipSnapToTheCutToo() throws {
        let (f, c, cut) = try cutJustAfterTen()
        try c.run("Room", .insertTime(at: t(10), duration: t(2)))
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), cut + t(2)])
        let slug = Clip(id: "clip_slug", content: .solid(color: .black), start: t(9.999), duration: t(1))
        try c.run("Slug", .insertClip(trackID: f.track("Camera").id, clip: slug, mode: .insert))
        XCTAssertEqual(c.clips("Camera").map(\.range), [
            TimeRange(start: t(0), end: cut),
            TimeRange(start: cut, end: cut + t(1)),
            TimeRange(start: cut + t(3), end: t(63))
        ])
    }

    /// What happened in the Tandem video: the agent took the first take to
    /// be the screen file's 282.1 s, but it was placed at the camera file's
    /// 282.045 s, so 625.1 was 55 ms into the clip after it.
    func testAnInsertJustInsideAClipWarnsWhereItStarts() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10), clipIDs: [f.clips("Camera")[0].id]))
        let result = try c.run("Insert", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: t(10.055), sourceStart: t(0.5), duration: t(5), mode: .insert))
        XCTAssertEqual(c.clips("Camera")[1].range, TimeRange(start: t(10), end: t(10.055)), "it still inserts where it's told")
        let warning = result.warnings.first { $0.contains("0.055 s") } ?? ""
        XCTAssertTrue(warning.contains("starts at 00:10.000") && warning.contains("Insert at 10 to move the whole clip"), "\(result.warnings)")
    }

    func testPlacingATakeSaysWhenItsFilesDifferInLength() throws {
        var fixture = Fixture()
        fixture.project.media[1].duration = t(60.555)
        let c = ProjectCoordinator(project: fixture.project)
        let result = try c.run("Place", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero))
        XCTAssertEqual(c.clips("Camera")[0].duration, t(60))
        XCTAssertTrue(result.warnings.contains { $0.contains("01:00.000") && $0.contains("take1-camera") }, "\(result.warnings)")
    }
}

/// Markers at an insert point stay before the inserted material (#30).
final class InsertMarkerTests: XCTestCase {
    func testAMarkerAtTheInsertPointStaysAndLaterOnesMove() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Marker", .addMarker(marker: Marker(id: "mk_later", time: t(31), name: "Later")))
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        try c.run("Insert", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: t(30), sourceStart: t(0.5), duration: t(5), mode: .insert))
        XCTAssertEqual(c.project.markers.first { $0.id == "mk_s2" }?.time, t(30), "the section starts with what was inserted")
        XCTAssertEqual(c.project.markers.first { $0.id == "mk_later" }?.time, t(36))
        XCTAssertEqual(c.clips("Camera")[1].start, t(30))
    }

    func testInsertTimeAtAMarkerLeavesIt() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Room", .insertTime(at: t(30), duration: t(2)))
        XCTAssertEqual(c.project.markers[0].time, t(30))
        try c.run("Room before it", .insertTime(at: t(29), duration: t(1)))
        XCTAssertEqual(c.project.markers[0].time, t(31))
    }

    func testRippleTrimmingTheEndBeforeAMarkerStillMovesIt() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        try c.run("Shorter", .trim(clipID: c.clips("Camera")[0].id, edge: .end, to: t(28), ripple: true))
        try c.run("Longer", .trim(clipID: c.clips("Camera")[0].id, edge: .end, to: t(29), ripple: true))
        XCTAssertEqual(c.project.markers[0].time, t(29), "the marker stays on the clip after the cut")
    }
}
