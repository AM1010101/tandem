import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem sync`: how late each file's picture is against its sound.
final class SyncTests: XCTestCase {
    func testItSetsTheCameraTakesAndLeavesTheSoundAlone() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let before = try h.service.sync(SyncRequest(), context: h.context)
        XCTAssertTrue(before.readableText.contains("med_camera  source/take1-camera.mov  camera  as recorded"), before.readableText)

        let result = try h.service.sync(SyncRequest(delay: t(0.08)), context: h.context)
        XCTAssertEqual(result.applied?.label, "Picture delay 80 ms on 1 file")
        XCTAssertEqual(result.applied?.author, "claude")
        let project = h.service.coordinator.project
        XCTAssertEqual(project.media("med_camera")?.pictureDelay, t(0.08))
        XCTAssertNil(project.media("med_screen")?.pictureDelay, "only camera takes by default")
        XCTAssertEqual(project.allTracks.flatMap(\.clips), APIFixture.project().allTracks.flatMap(\.clips), "no clip moves")
        XCTAssertTrue(result.readableText.contains("camera  80 ms"), result.readableText)
        let media = try await h.service.media(refresh: false).readableText
        XCTAssertTrue(media.contains("picture 80 ms late, shown in sync"), media)

        // The same again changes nothing; 0 puts it back; a file named gets it.
        XCTAssertNil(try h.service.sync(SyncRequest(delay: t(0.08)), context: h.context).applied)
        _ = try h.service.sync(SyncRequest(delay: .zero), context: h.context)
        XCTAssertNil(h.service.coordinator.project.media("med_camera")?.pictureDelay)
        _ = try h.service.sync(SyncRequest(delay: t(0.05), media: ["med_screen"]), context: h.context)
        XCTAssertEqual(h.service.coordinator.project.media("med_screen")?.pictureDelay, t(0.05))

        XCTAssertThrowsError(try h.service.sync(SyncRequest(delay: t(80)), context: h.context)) { error in
            XCTAssertTrue((error as? ServiceError)?.message.contains("80 ms is 0.08") == true, "\(error)")
        }
        XCTAssertThrowsError(try h.service.sync(SyncRequest(delay: t(0.08), media: ["med_music"]), context: h.context))
    }
}

extension SyncTests {
    func testATakeRecordItCorrectedIsLeftInSync() throws {
        var project = APIFixture.project()
        let index = try XCTUnwrap(project.media.firstIndex { $0.id == "med_camera" })
        project.media[index].pictureDelayCorrected = t(0.08)
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        let result = try h.service.sync(SyncRequest(delay: t(0.08)), context: h.context)
        XCTAssertNil(result.applied, "nothing to do: Record It took the delay out")
        XCTAssertNil(h.service.coordinator.project.media("med_camera")?.pictureDelay)
        XCTAssertTrue(result.readableText.contains("as recorded, in sync as recorded (Record It took out 80 ms)"), result.readableText)
    }
}

/// `tandem sync` as agents run it.
final class SyncCLITests: XCTestCase {
    private let cli = CLITests()

    func testAnAgentSyncsTheTakeAndSetsTheDefault() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let settings = folder.file("settings.json")
        let env = ["TANDEM_SETTINGS": settings.path]

        let set = try cli.tandem("sync", "80ms", "--default", "--author", "claude", in: folder.url, env: env)
        XCTAssertEqual(set.status, 0, set.stderr)
        XCTAssertTrue(set.stdout.contains("Applied \"Picture delay 80 ms on 1 file\" by claude"), set.stdout)
        XCTAssertTrue(set.stdout.contains("New camera takes get 80 ms"), set.stdout)
        XCTAssertEqual(try ProjectFile.load(from: url).project.media("med_camera")?.pictureDelay, t(0.08))
        XCTAssertEqual(TandemSettings.load(from: settings).cameraPictureDelay, 0.08)

        let bad = try cli.tandem("sync", "soon", in: folder.url, env: env)
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.stderr.contains("isn't a delay"), bad.stderr)
    }
}

/// `tandem sync <file>...`: another angle and an external mic lined up with
/// the camera by sound, put in its take and placed beside it in one step.
final class SoundSyncAPITests: XCTestCase {
    /// A 120 s camera take on the timeline, and a close-up and a mic that
    /// started 2.855 s before it and stop after 60 s, with their files in
    /// `folder`.
    static func interview(in folder: URL) throws -> Project {
        try writeSounds(in: folder)
        return try interview()
    }

    static func writeSounds(in folder: URL) throws {
        let room = SyncRoom(seconds: 125)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("source"), withIntermediateDirectories: true)
        try room.record(to: folder.appendingPathComponent("source/wide.wav"), from: 3, seconds: 120, seed: 2)
        try room.record(to: folder.appendingPathComponent("source/close-up.wav"), from: 0.145, seconds: 60, seed: 3)
        try room.record(to: folder.appendingPathComponent("source/mic.wav"), from: 0.145, seconds: 60, seed: 4)
        try SyncRoom(seconds: 60, seed: 99).record(to: folder.appendingPathComponent("source/other.wav"), from: 0, seconds: 50, seed: 5)
    }

    static func interview() throws -> Project {
        var project = Project.standard(name: "Interview")
        project.media = [
            MediaItem(id: "med_wide", path: "source/wide.wav", kind: .video, role: .camera, duration: t(120), frameRate: .fps30,
                      width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_close", path: "source/close-up.wav", kind: .video, role: .broll, duration: t(60), frameRate: .fps30,
                      width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_mic", path: "source/mic.wav", kind: .audio, role: .music, duration: t(60), hasAudio: true),
            MediaItem(id: "med_other", path: "source/other.wav", kind: .audio, role: .other, duration: t(50), hasAudio: true)
        ]
        let coordinator = ProjectCoordinator(project: project)
        try coordinator.apply(EditBatch(label: "Place", commands: [.placeMedia(mediaIDs: ["med_wide"], at: .zero)]))
        return coordinator.project
    }

    func testAnAngleAndAMicAreLinedUpPutInTheTakeAndPlacedAsOneUndoStep() async throws {
        let h = try ServiceHarness(project: Self.interview())
        defer { h.close() }
        try Self.writeSounds(in: h.folder.url)
        let before = h.service.coordinator.project
        let result = try await h.service.syncBySound(SyncRequest(files: ["med_close", "source/mic.wav"]), context: h.context)

        let matches = try XCTUnwrap(result.matches)
        XCTAssertEqual(matches.map(\.id), ["med_close", "med_mic"])
        for match in matches {
            XCTAssertEqual(match.offset, 2.855, accuracy: 0.0005, match.id)
            XCTAssertEqual(try XCTUnwrap(match.drift), 0, accuracy: 0.0005)
            XCTAssertGreaterThan(match.confidence, SoundSync.minimumConfidence)
        }
        let project = h.service.coordinator.project
        let wide = try XCTUnwrap(project.media("med_wide"))
        XCTAssertNotNil(wide.takeID)
        XCTAssertEqual(try XCTUnwrap(wide.takeOffset).seconds, 2.855, accuracy: 0.0005, "the camera started 2.855 s into the take")
        XCTAssertEqual(project.media("med_close")?.takeOffset, .zero)
        XCTAssertEqual(project.media("med_mic")?.takeID, wide.takeID)
        XCTAssertEqual(project.media("med_mic")?.role, .other, "the scan took the recorder's file for music; it's a voice")
        XCTAssertEqual(matches[0].tracks, ["Angle 2"])
        XCTAssertEqual(matches[1].tracks, ["Voice"])
        XCTAssertTrue(project.track(named: "Camera sound")?.muted == true)
        XCTAssertEqual(result.applied?.label, "Sync 2 files to wide by sound")
        XCTAssertTrue(result.readableText.contains("+2.85"), result.readableText)
        XCTAssertTrue(result.readableText.contains("On \"Angle 2\"."), result.readableText)

        _ = try h.service.undo(expectedRevision: nil)
        XCTAssertEqual(h.service.coordinator.project, before, "one undo step")
    }

    func testADryRunMeasuresAndAFileThatDoesntMatchIsRefused() async throws {
        let h = try ServiceHarness(project: Self.interview())
        defer { h.close() }
        try Self.writeSounds(in: h.folder.url)
        let before = h.service.coordinator.snapshot()
        let dry = try await h.service.syncBySound(SyncRequest(files: ["med_mic"], dryRun: true), context: h.context)
        XCTAssertEqual(dry.matches?.first?.offset ?? 0, 2.855, accuracy: 0.0005)
        XCTAssertEqual(dry.applied?.dryRun, true)
        XCTAssertTrue(dry.readableText.contains("Dry run: nothing changed"), dry.readableText)
        XCTAssertEqual(h.service.coordinator.snapshot().revision, before.revision)

        do {
            _ = try await h.service.syncBySound(SyncRequest(files: ["med_other"]), context: h.context)
            XCTFail("an unrelated recording was lined up")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("doesn't line up with wide.wav by sound"), error.message)
        }
        XCTAssertEqual(h.service.coordinator.snapshot().revision, before.revision)

        // Only the take, nothing placed.
        let take = try await h.service.syncBySound(SyncRequest(files: ["med_mic"], place: false), context: h.context)
        XCTAssertEqual(take.matches?.first?.tracks, [])
        XCTAssertNotNil(h.service.coordinator.project.media("med_mic")?.takeID)
        XCTAssertNil(h.service.coordinator.project.track(named: "Camera sound"))
    }
}

/// `tandem sync <file>...` as agents run it.
final class SoundSyncCLITests: XCTestCase {
    private let cli = CLITests()

    func testAnAgentSyncsAMicAndAnAngleByPathThenShowsTheAngle() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url, project: SoundSyncAPITests.interview(in: folder.url))
        let synced = try cli.tandem("sync", "source/close-up.wav", "source/mic.wav", "--author", "claude", in: folder.url)
        XCTAssertEqual(synced.status, 0, synced.stderr)
        XCTAssertTrue(synced.stdout.contains("Lined up with source/wide.wav by sound"), synced.stdout)
        XCTAssertTrue(synced.stdout.contains("Applied \"Sync 2 files to wide by sound\" by claude"), synced.stdout)

        let shown = try cli.tandem("apply", #"{"showAngle": {"range": {"start": 10, "end": 20}, "trackID": "Angle 2"}}"#, in: folder.url)
        XCTAssertEqual(shown.status, 0, shown.stderr)
        let project = try ProjectFile.load(from: url).project
        XCTAssertEqual(project.track(named: "Angle 2")?.clips.filter(\.enabled).map(\.range), [TimeRange(start: t(10), end: t(20))])

        let refused = try cli.tandem("sync", "source/other.wav", in: folder.url)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.stderr.contains("doesn't line up"), refused.stderr)
    }
}

extension SoundSyncCLITests {
    func testTheMCPToolLinesAMicUpAndPlacesIt() async throws {
        let mcp = try MCPHarness(author: "claude")
        try ProjectFile.save(SoundSyncAPITests.interview(), revision: 1, to: mcp.projectURL)
        try SoundSyncAPITests.writeSounds(in: mcp.folder.url)
        let response = try await mcp.tool(1, "sync", #"{"files": ["source/mic.wav"], "json": true}"#)
        XCTAssertEqual(response[json: "result"]?[json: "isError"], .bool(false))
        let text = try XCTUnwrap(response[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        let result = try ServiceJSON.decoder().decode(SyncResult.self, from: Data(text.utf8))
        let match = try XCTUnwrap(result.matches?.first)
        XCTAssertEqual(match.offset, 2.855, accuracy: 0.0005)
        XCTAssertEqual(match.tracks, ["Voice"])
        XCTAssertEqual(result.applied?.author, "claude")
        await mcp.close()
    }
}

/// A made-up room for the tests above: bursts of noise like syllables.
private struct SyncRoom {
    static let rate = 48_000.0
    var samples: [Float]

    init(seconds: Double, seed: UInt64 = 1) {
        var state = seed
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        samples = [Float](repeating: 0, count: Int(seconds * Self.rate))
        var i = 0
        var smooth: Float = 0
        while i < samples.count {
            let burst = Int((0.06 + random() * 0.3) * Self.rate)
            let gap = Int((0.04 + random() * 0.45) * Self.rate)
            let level = Float(0.05 + random() * 0.35)
            for j in 0..<burst where i + j < samples.count {
                smooth = 0.6 * smooth + 0.4 * Float(random() * 2 - 1)
                samples[i + j] = level * Float(sin(Double.pi * Double(j) / Double(burst))) * smooth
            }
            i += burst + gap
        }
    }

    func record(to url: URL, from: Double, seconds: Double, seed: UInt64) throws {
        var state = seed
        let count = Int(seconds * Self.rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let start = Int(from * Self.rate)
        for n in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let hiss = Float(Double(state >> 11) / Double(1 << 53) * 2 - 1) * 0.004
            buffer.floatChannelData![0][n] = (start + n < samples.count ? samples[start + n] : 0) + hiss
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
