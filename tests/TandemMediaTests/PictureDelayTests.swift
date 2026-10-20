import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// A webcam's picture lags its mic: Tandem's setting for it, and new
/// camera takes getting it as they join a project.
final class PictureDelayTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    func testNewCameraTakesGetTheSettingAndNothingElseDoes() async throws {
        try await SyntheticMedia.writeMovie(to: file("source/2026-10-02_122619-camera.mov"), .init(width: 320, height: 180, duration: 1))
        try await SyntheticMedia.writeMovie(to: file("broll/clip.mp4"), .init(width: 320, height: 180, duration: 1))
        let settings = TandemSettings(cameraPictureDelay: 0.08)
        let first = try await MediaScanner.scanReport(folder, known: [], settings: settings)
        let camera = try XCTUnwrap(first.items.first { $0.role == .camera })
        XCTAssertEqual(camera.pictureDelay, Time(seconds: 0.08))
        XCTAssertNil(first.items.first { $0.path == "broll/clip.mp4" }?.pictureDelay, "only camera takes")

        // A take Mike set back to as recorded stays that way on a rescan.
        var known = first.items
        let index = try XCTUnwrap(known.firstIndex { $0.id == camera.id })
        known[index].pictureDelay = nil
        let again = try await MediaScanner.scan(folder, known: known, settings: settings)
        XCTAssertNil(again.first { $0.id == camera.id }?.pictureDelay)

        // Without a setting, nothing changes.
        let plain = try await MediaScanner.scanReport(folder, known: [], settings: TandemSettings())
        XCTAssertNil(plain.items.first { $0.role == .camera }?.pictureDelay)

        // One file dropped in gets it too.
        let dropped = try await MediaScanner.probe(file("source/2026-10-02_122619-camera.mov"), folder: folder, settings: settings)
        XCTAssertEqual(dropped.pictureDelay, Time(seconds: 0.08))
    }

    func testATakeRecordItAlreadyCorrectedGetsNoMoreDelay() async throws {
        var spec = SyntheticMedia.Video(width: 320, height: 180, duration: 1)
        spec.metadata = [AVMetadataItem.identifier(forKey: "com.mikerosoft.record-it.camera-delay", keySpace: .quickTimeMetadata)!: "0.080"]
        try await SyntheticMedia.writeMovie(to: file("source/2026-10-03_101500-camera.mov"), spec)
        try await SyntheticMedia.writeMovie(to: file("source/2026-09-30_090000-camera.mov"), .init(width: 320, height: 180, duration: 1))
        let report = try await MediaScanner.scanReport(folder, known: [], settings: TandemSettings(cameraPictureDelay: 0.08))
        let corrected = try XCTUnwrap(report.items.first { $0.path.contains("2026-10-03") })
        XCTAssertEqual(corrected.pictureDelayCorrected, Time(seconds: 0.08), "Record It's tag")
        XCTAssertNil(corrected.pictureDelay, "in sync as recorded: no second delay")
        let older = try XCTUnwrap(report.items.first { $0.path.contains("2026-09-30") })
        XCTAssertNil(older.pictureDelayCorrected)
        XCTAssertEqual(older.pictureDelay, Time(seconds: 0.08), "a take from before Record It corrected them still gets Tandem's")
    }

    func testOnlyWebcamTakesGetTheDelay() async throws {
        // A cinema camera's clip (a REDline render keeps its timecode track)
        // and a phone or camera's (its make and model) record in step.
        var red = SyntheticMedia.Video(width: 320, height: 180, fps: 24, duration: 1)
        red.timecodeFrame = 1_185_018
        try await SyntheticMedia.writeMovie(to: file("source/interview-camera.mov"), red)
        var phone = SyntheticMedia.Video(width: 320, height: 180, duration: 1)
        phone.metadata = [.quickTimeMetadataMake: "Apple", .quickTimeMetadataModel: "iPhone 16 Pro"]
        try await SyntheticMedia.writeMovie(to: file("source/phone-camera.mov"), phone)
        // Mike's webcam through Record It writes neither.
        try await SyntheticMedia.writeMovie(to: file("source/2026-10-02_122619-camera.mov"), .init(width: 320, height: 180, duration: 1))

        let settings = TandemSettings(cameraPictureDelay: 0.08)
        let report = try await MediaScanner.scanReport(folder, known: [], settings: settings)
        func item(_ path: String) throws -> MediaItem { try XCTUnwrap(report.items.first { $0.path == path }, path) }
        XCTAssertEqual(try item("source/interview-camera.mov").role, .camera)
        XCTAssertNil(try item("source/interview-camera.mov").pictureDelay, "a timecode track: a camera, not the webcam")
        XCTAssertNil(try item("source/phone-camera.mov").pictureDelay, "a phone names itself")
        XCTAssertEqual(try item("source/2026-10-02_122619-camera.mov").pictureDelay, Time(seconds: 0.08))

        let dropped = try await MediaScanner.probe(file("source/interview-camera.mov"), folder: folder, settings: settings)
        XCTAssertNil(dropped.pictureDelay, "a file dropped in is judged the same way")

        let probe = try await MediaProbe.probe(file("source/interview-camera.mov"))
        XCTAssertTrue(probe.shotOnCamera)
        XCTAssertEqual(probe.frameRate, FrameRate(24), "the timecode track isn't taken for the picture")
        let webcam = try await MediaProbe.probe(file("source/2026-10-02_122619-camera.mov"))
        XCTAssertFalse(webcam.shotOnCamera)
        XCTAssertNil(TandemSettings(cameraPictureDelay: 0.08).pictureDelay(
            for: MediaItem(path: "a.mov", kind: .video, role: .camera, hasVideo: true, hasAudio: true), shotOnCamera: true
        ))
    }

    func testTheSettingsFileReadsBackAndToleratesItsAbsence() throws {
        let url = file("settings/settings.json")
        XCTAssertEqual(TandemSettings.load(from: url), TandemSettings(), "no file: the defaults")
        try TandemSettings(cameraPictureDelay: 0.08).save(to: url)
        XCTAssertEqual(TandemSettings.load(from: url).cameraPictureDelay, 0.08)
        try Data(#"{"cameraPictureDelay": 0.1, "fromANewerTandem": true}"#.utf8).write(to: url)
        XCTAssertEqual(TandemSettings.load(from: url).cameraPictureDelay, 0.1)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(TandemSettings.load(from: url), TandemSettings())
        XCTAssertNotEqual(TandemSettings.url.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tandem/settings.json").path, "tests never use Mike's")
    }

    func testTheDelayRoundTripsInTheProject() throws {
        let item = MediaItem(id: "med_cam", path: "cam.mov", kind: .video, role: .camera, hasVideo: true, hasAudio: true, pictureDelay: Time(seconds: 0.075))
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).pictureDelay, Time(seconds: 0.075))
    }
}
