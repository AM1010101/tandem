import AppKit
import XCTest
@testable import TandemApp
import TandemCore

@MainActor
final class PlaybackControllerTests: XCTestCase {
    override func setUp() async throws {
        // ViewerAudio needs the Mac's media services, as the editor does.
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        PlaybackController.muted = true
    }

    func testScrubbingResumesEveryShuttleRateFromTheReleasedPlayhead() {
        let playback = PlaybackController()
        defer { playback.invalidate() }
        playback.projectChanged(duration: t(60), frameRate: .fps30)
        for rate in [1.0, 2, 4, 8, -1, -2, -4, -8] {
            playback.seek(to: t(10))
            playback.play(rate: rate)
            playback.beginScrub()
            XCTAssertFalse(playback.isPlaying)
            playback.seek(to: t(20))
            playback.seek(to: t(25))
            XCTAssertFalse(playback.isPlaying, "seeking during the scrub stays silent")
            playback.endScrub()
            XCTAssertEqual(playback.rate, rate)
            XCTAssertEqual(playback.time, t(25))
            playback.pause()
        }
    }

    func testScrubbingWhilePausedStaysPausedAndDoesNotReuseAnEarlierRate() {
        let playback = PlaybackController()
        defer { playback.invalidate() }
        playback.projectChanged(duration: t(60), frameRate: .fps30)
        playback.play(rate: 4)
        playback.beginScrub()
        playback.endScrub()
        playback.pause()
        playback.beginScrub()
        playback.seek(to: t(20))
        playback.endScrub()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.time, t(20))
    }

    func testRepeatedScrubCallsDoNotLoseOrReuseTheRememberedRate() {
        let playback = PlaybackController()
        defer { playback.invalidate() }
        playback.projectChanged(duration: t(60), frameRate: .fps30)
        playback.seek(to: t(10))
        playback.play(rate: -4)
        playback.beginScrub()
        playback.beginScrub()
        playback.seek(to: t(20))
        playback.endScrub()
        XCTAssertEqual(playback.rate, -4)
        playback.pause()
        playback.endScrub()
        XCTAssertFalse(playback.isPlaying)
    }
}
