import XCTest
@testable import TandemAPI
@testable import TandemCore

extension CLITests {
    /// The batches agents sent while editing the Tandem video, through
    /// `tandem apply`: B-roll placed at a speed (#53), and one clip bladed
    /// twice in a batch, then where it isn't (#51).
    func testApplyPlacesAtASpeedAndBladesOneClipTwice() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)

        let placed = try tandem("apply", #"{"placeMedia": {"mediaIDs": ["med_broll"], "at": 40, "duration": 4, "speed": 2}}"#, in: folder.url)
        XCTAssertEqual(placed.status, 0, placed.stderr)
        var project = try ProjectFile.load(from: url).project
        let broll = try XCTUnwrap(project.track(named: "B-roll")?.clips.last)
        XCTAssertEqual(broll.speed, 2)
        XCTAssertEqual(broll.range, TimeRange(start: t(40), end: t(44)))
        XCTAssertEqual(broll.sourceEnd, t(8))

        let cuts = try tandem("apply", #"[{"blade": {"at": 35, "clipIDs": ["clip_cam2"]}}, {"blade": {"at": 45, "clipIDs": ["clip_cam2"]}}]"#, in: folder.url)
        XCTAssertEqual(cuts.status, 0, cuts.stderr)
        project = try ProjectFile.load(from: url).project
        XCTAssertEqual(project.track(named: "Camera")?.clips.map(\.start), [t(0), t(30), t(35), t(45)])
        XCTAssertEqual(project.track(named: "Voice")?.clips.map(\.start), [t(0), t(30), t(35), t(45)])

        let missed = try tandem("apply", #"{"blade": {"at": 20, "clipIDs": ["clip_cam2"]}}"#, in: folder.url)
        XCTAssertNotEqual(missed.status, 0)
        XCTAssertTrue((missed.stdout + missed.stderr).contains("clip clip_cam2 runs from 00:30.000 to 00:35.000"), missed.stdout + missed.stderr)
    }
}
