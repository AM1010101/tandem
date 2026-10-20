import XCTest
@testable import TandemCore

/// Stretches of a screen recording that play at a low frame rate while the
/// picture moves. In the Tandem video Mike's screen capture dropped to 4 to
/// 7 fps while he was away from his desk (macOS records the screen when it
/// changes), and he spotted "a really low frame rate" in review.
final class LowFrameRateTests: XCTestCase {
    static let screen = MediaItem(id: "med_screen", path: "take-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3840, height: 2160, hasVideo: true, variableFrameRate: true)
    static let camera = MediaItem(id: "med_camera", path: "take-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true)

    /// A 4K, 30 fps edit: the screen recording from 0 to 20 s (from 100 s
    /// into its file, at `speed`), and the camera in the corner, or full
    /// frame over the screen from 4 to 12 s with `fullCamera`.
    private func edit(speed: Double = 1, fullCamera: Bool = false) -> Project {
        var project = Project.standard(name: "Frames")
        project.settings.width = 3840
        project.settings.height = 2160
        project.settings.frameRate = .fps30
        project.media = [Self.screen, Self.camera]
        project.videoTracks[0].clips = [Clip(id: "clip_s", content: .media(mediaID: "med_screen"), start: .zero, duration: t(20), sourceStart: t(100), speed: speed)]
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.3))
        project.videoTracks[1].clips = [Clip(id: "clip_cam", content: .media(mediaID: "med_camera"), start: .zero, duration: t(20), video: pip)]
        if fullCamera {
            project.videoTracks[1].clips = [
                Clip(id: "clip_cam", content: .media(mediaID: "med_camera"), start: .zero, duration: t(4), video: pip),
                Clip(id: "clip_cam2", content: .media(mediaID: "med_camera"), start: t(4), duration: t(8), sourceStart: t(4)),
                Clip(id: "clip_cam3", content: .media(mediaID: "med_camera"), start: t(12), duration: t(8), sourceStart: t(12), video: pip)
            ]
        }
        return project
    }

    /// The recording's frame times (file time): 30 a second, except `fps`
    /// a second from `from` to `to`, a little uneven as macOS's are.
    private func times(lowFrom from: Double = 105, to: Double = 109, fps: Double = 5) -> [Time] {
        var times: [Time] = []
        var time = 90.0
        var n = 0
        while time < 200 {
            times.append(Time(seconds: time))
            let low = time >= from && time < to
            time += low ? (1 / fps) * (n % 2 == 0 ? 0.8 : 1.2) : 1.0 / 30
            n += 1
        }
        return times
    }

    /// The recording scanned on its own at 30 fps over the timeline's first
    /// 20 s: a new picture at every one of its frames when `moving`
    /// (something sliding across it), otherwise a still page.
    private func screenFrames(_ project: Project, sourceTimes: [Time], moving: Bool) -> [FrameStats] {
        let clip = project.videoTracks[0].clips[0]
        return (0..<600).map { index in
            let time = Time(seconds: Double(index) / 30)
            let source = clip.sourceTime(atTimelineTime: time)
            let shown = sourceTimes.lastIndex { $0 <= source } ?? 0
            let tiles = (0..<(32 * 18)).map { tile -> UInt8 in
                guard moving else { return 30 }
                return tile % 32 == shown % 32 ? 200 : 30
            }
            return FrameStats(time: time, luma: 0.1, brightestTile: 0.8, flatGreen: 0, flatWhite: 0, thumbnail: tiles, columns: 32)
        }
    }

    private func check(_ project: Project, sourceTimes: [Time], moving: Bool = true) -> [CheckProblem] {
        QualityCheck.lowFrameRates(
            in: project, ranges: [TimeRange(start: .zero, end: t(20))], frameTimes: ["med_screen": sourceTimes],
            screenFrames: screenFrames(project, sourceTimes: sourceTimes, moving: moving)
        )
    }

    func testAMovingStretchAtFiveFramesASecondIsANote() throws {
        let found = check(edit(), sourceTimes: times())
        XCTAssertEqual(found.map(\.kind), [.lowFrameRate])
        let note = try XCTUnwrap(found.first)
        XCTAssertTrue(note.kind.isNote)
        XCTAssertEqual(note.start.seconds, 5, accuracy: 0.51)
        XCTAssertEqual(note.end.seconds, 9, accuracy: 0.51)
        XCTAssertEqual(note.clipIDs, ["clip_s"])
        XCTAssertTrue(note.message.contains("about 5 fps"), note.message)
        XCTAssertTrue(note.message.contains("full screen on his camera"), note.message)
    }

    func testAStillScreenAtALowRateLooksTheSameSoItsFine() {
        XCTAssertTrue(check(edit(), sourceTimes: times(), moving: false).isEmpty, "a still page at 5 fps looks the same as at 30")
    }

    func testItGoesByTheRateTheTimelineShows() {
        XCTAssertTrue(check(edit(speed: 4), sourceTimes: times()).isEmpty, "5 fps played at 4x is 20 a second")
        let slow = check(edit(speed: 0.25), sourceTimes: times(lowFrom: 0, to: 0))
        XCTAssertEqual(slow.map(\.kind), [.lowFrameRate], "30 fps at a quarter speed is 7.5 a second")
    }

    func testNotWhereTheViewerDoesntSeeTheScreen() {
        XCTAssertTrue(check(edit(fullCamera: true), sourceTimes: times()).isEmpty, "under the camera full frame, as Mike fixed it")
    }

    func testTooShortToNotice() {
        XCTAssertTrue(check(edit(), sourceTimes: times(lowFrom: 105, to: 105.6)).isEmpty)
    }

    func testOnlyWithinTheRangesChecked() {
        let found = QualityCheck.lowFrameRates(
            in: edit(), ranges: [TimeRange(start: t(12), end: t(20))], frameTimes: ["med_screen": times()],
            screenFrames: screenFrames(edit(), sourceTimes: times(), moving: true)
        )
        XCTAssertTrue(found.isEmpty)
    }
}
