import XCTest
@testable import TandemAPI
import TandemCore

/// What a new project takes from the media it finds. The end-to-end
/// `tandem new` runs are in CLITests.
final class NewProjectTests: XCTestCase {
    func take(_ path: String, _ rate: FrameRate?, seconds: Double, role: MediaRole = .camera, kind: MediaKind = .video, variable: Bool = false) -> MediaItem {
        var item = MediaItem(path: path, kind: kind, role: role, duration: Time(seconds: seconds), hasVideo: kind == .video, hasAudio: true)
        item.frameRate = rate
        item.variableFrameRate = variable
        return item
    }

    func testTheCameraTakesFrameRate() {
        func rate(_ media: [MediaItem]) -> FrameRate? { ProjectSession.cameraFrameRate(media) }
        // Ian's RED take, with a shorter close-up angle (b-roll) and the mic.
        XCTAssertEqual(rate([
            take("source/Ian - A004_A002_0904XF.mov", FrameRate(24_000, 1001), seconds: 2753),
            take("source/Ian close-up - B047_C002_0101QF.mov", FrameRate(25), seconds: 1080, role: .broll),
            take("source/Ian mic.wav", nil, seconds: 1080, kind: .audio)
        ]), FrameRate(24_000, 1001))
        // The longest camera take decides.
        XCTAssertEqual(rate([take("a-camera.mov", FrameRate(25), seconds: 60), take("b-camera.mov", FrameRate(24), seconds: 600)]), FrameRate(24))
        // Mike's webcam: 30 stays 30, and 60 drops to 30.
        XCTAssertEqual(rate([take("t1-camera.mov", FrameRate(30), seconds: 60)]), FrameRate(30))
        XCTAssertEqual(rate([take("t1-camera.mov", FrameRate(60), seconds: 60)]), FrameRate(30))
        XCTAssertEqual(rate([take("t1-camera.mov", FrameRate(60_000, 1001), seconds: 60)]), FrameRate(30_000, 1001))
        XCTAssertEqual(rate([take("t1-camera.mov", FrameRate(50), seconds: 60)]), FrameRate(25))
        XCTAssertEqual(rate([take("t1-camera.mov", FrameRate(120), seconds: 60)]), FrameRate(30))
        // Nothing to go on: no camera take, a variable one, or a crawl.
        XCTAssertNil(rate([take("screen.mov", FrameRate(24), seconds: 60, role: .screen)]))
        XCTAssertNil(rate([take("t1-camera.mov", FrameRate(24), seconds: 60, variable: true)]))
        XCTAssertNil(rate([take("t1-camera.mov", FrameRate(15), seconds: 60)]))
        XCTAssertNil(rate([take("t1-camera.mov", nil, seconds: 60)]))
    }
}
