import XCTest
@testable import TandemAPI
@testable import TandemCore

/// `tandem diff`, `tandem restore`, `tandem clips` and history that says
/// where each edit was.
final class DiffTests: XCTestCase {
    private func gain(_ db: Double) -> JSONValue { .object(["audio": .object(["gainDB": .number(db)])]) }

    func testDiffSinceARevisionGroupsByEditAndAuthor() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.trim(clipID: "clip_brl1", edge: .start, to: t(21)), label: "Trim the B-roll")
        _ = try h.service.apply(ApplyRequest(label: "Quieter music", author: "user", commands: [.updateClip(clipID: "clip_mus1", patch: gain(-35))]), context: h.context)

        let diff = try h.service.diff(DiffRequest(since: "1"))
        XCTAssertEqual(diff.revision, 3)
        XCTAssertEqual(diff.sinceRevision, 1)
        XCTAssertEqual(diff.edits?.map(\.label), ["Trim the B-roll", "Quieter music"])
        XCTAssertEqual(diff.edits?.map(\.author), ["claude", "user"])
        XCTAssertEqual(diff.edits?.first?.tracks, ["V3 B-roll"])
        XCTAssertEqual(Set(diff.changes.map(\.id)), ["clip_brl1", "clip_mus1"])
        let brl = try XCTUnwrap(diff.changes.first { $0.id == "clip_brl1" })
        XCTAssertNotNil(brl.before, "full detail in the JSON")
        XCTAssertNotNil(brl.after)

        let text = diff.readableText
        XCTAssertTrue(text.contains("r2  Trim the B-roll  by claude  00:20.000-00:21.000 on V3 B-roll"), text)
        XCTAssertTrue(text.contains("changed  clip_brl1  V3 B-roll  00:21.000-00:25.000  servers.mp4: start +1.000s"), text)
        XCTAssertTrue(text.contains("r3  Quieter music  by user"), text)
        XCTAssertTrue(text.contains("gain -31 -> -35 dB"), text)

        let now = try h.service.diff(DiffRequest(since: "3"))
        XCTAssertTrue(now.changes.isEmpty)
        XCTAssertTrue(now.readableText.contains("No clips changed"), now.readableText)
        assertServiceError(.badRequest) { _ = try h.service.diff(DiffRequest(since: "9")) }
    }

    func testRippledClipsAreSummedUpNotListedOneByOne() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11))), label: "Tighten")
        let text = try h.service.diff(DiffRequest(since: "1")).readableText
        XCTAssertTrue(text.contains("clips by -1.000s on"), text)
        XCTAssertTrue(text.contains("cut at 00:10.000, the rest is"), text)
        XCTAssertFalse(text.contains("clip_cam2  V2 Camera"), "riding along is one line: \(text)")
    }

    /// The history is kept in a file, so it lasts from one CLI command to
    /// the next (and across app restarts), unlike the undo stack.
    func testTheHistoryLastsAcrossCommandsAndSaysWhereEachEditWas() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        _ = try headless(url) {
            try $0.apply(ApplyRequest(label: "Lift the B-roll", commands: [.removeClips(clipIDs: ["clip_brl1"])]), context: CallContext(author: "claude"))
        }
        _ = try headless(url) {
            try $0.apply(ApplyRequest(label: "Marker", commands: [.addMarker(marker: Marker(time: t(5), name: "Note"))]), context: CallContext(author: "user"))
        }
        let history = try headless(url) { $0.history(limit: 10) }
        let edits = try XCTUnwrap(history.edits)
        XCTAssertEqual(edits.first?.label, "Marker")
        let lift = try XCTUnwrap(edits.first { $0.label == "Lift the B-roll" })
        XCTAssertEqual(lift.revision, 2)
        XCTAssertEqual(lift.start, t(20))
        XCTAssertEqual(lift.end, t(25))
        XCTAssertEqual(lift.tracks, ["V3 B-roll"])
        XCTAssertEqual(history.undo.first { $0.label == "Lift the B-roll" }?.tracks, ["V3 B-roll"], "undo says where too")
        let text = history.readableText
        XCTAssertTrue(text.contains("Lift the B-roll  (claude)  00:20.000-00:25.000 on V3 B-roll"), text)
        XCTAssertTrue(text.contains("r3"), text)

        let diff = try headless(url) { try $0.diff(DiffRequest(since: "1")) }
        XCTAssertEqual(diff.changes.map(\.kind), [.removed])
        XCTAssertEqual(diff.edits?.map(\.label), ["Lift the B-roll", "Marker"])
    }

    func testDiffSinceAnExportSnapshotOrABackup() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let original = h.service.coordinator.project
        let exports = h.folder.url.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        // Exports write their snapshot with revision 0.
        try ProjectFile.encoder().encode(ProjectFile.Envelope(revision: 0, project: original)).write(to: exports.appendingPathComponent("v1.mp4.tandem"))
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(5)), label: "Move")

        // The export itself names its snapshot.
        let diff = try h.service.diff(DiffRequest(since: "exports/v1.mp4"))
        XCTAssertNil(diff.edits)
        XCTAssertNil(diff.sinceRevision)
        XCTAssertEqual(diff.changes.map(\.details), [["moved +5.000s"]])
        XCTAssertTrue(diff.since.contains("v1.mp4.tandem"), diff.since)

        // A backup knows its revision, and the history reaches it.
        let backups = h.folder.url.appendingPathComponent(".tandem/backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent("Decision Models 2026-10-17 10.00.00.tandem")
        try ProjectFile.encoder().encode(ProjectFile.Envelope(revision: 1, project: original)).write(to: backup)
        let fromBackup = try h.service.diff(DiffRequest(since: backup.path))
        XCTAssertEqual(fromBackup.sinceRevision, 1)
        XCTAssertEqual(fromBackup.edits?.map(\.label), ["Move"])

        assertServiceError(.notFound) { _ = try h.service.diff(DiffRequest(since: "exports/nothing.mp4")) }
    }

    func testARevisionTheHistoryDoesntReachComesFromABackupOrSaysWhatToUse() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.removeClips(clipIDs: ["clip_brl1"]), label: "Lift")
        assertServiceError(.notFound) { _ = try h.service.diff(DiffRequest(since: "0")) }
        do {
            _ = try h.service.diff(DiffRequest(since: "0"))
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("goes back to revision 1"), error.message)
            XCTAssertTrue(error.message.contains(".mp4.tandem"), "says snapshots work: \(error.message)")
        }

        let backups = h.folder.url.appendingPathComponent(".tandem/backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try ProjectFile.encoder().encode(ProjectFile.Envelope(revision: 0, project: APIFixture.project()))
            .write(to: backups.appendingPathComponent("Decision Models 2026-10-17 09.00.00.tandem"))
        let diff = try h.service.diff(DiffRequest(since: "0"))
        XCTAssertEqual(diff.sinceRevision, 0)
        XCTAssertTrue(diff.since.contains("backup"), diff.since)
        XCTAssertEqual(diff.changes.map(\.id), ["clip_brl1"])
    }

    // MARK: - restore

    func testRestorePutsClipsBackAsOneUndoStep() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let original = h.service.coordinator.project
        try h.apply(.removeClips(clipIDs: ["clip_brl1"]), label: "Lift")
        try h.apply(.updateClip(clipID: "clip_mus1", patch: gain(-20)), label: "Louder")

        let plan = try h.service.restore(RestoreRequest(from: "1", clips: ["clip_brl1", "clip_mus1", "clip_cam1"]), context: h.context)
        XCTAssertNil(plan.applied)
        XCTAssertEqual(h.service.coordinator.revision, 3, "a dry run changes nothing")
        XCTAssertEqual(plan.items.map(\.action), [.putBack, .unchanged, .changeBack])
        XCTAssertEqual(plan.items.map(\.id), ["clip_brl1", "clip_cam1", "clip_mus1"])
        let text = plan.readableText
        XCTAssertTrue(text.contains("put back  clip_brl1  V3 B-roll  00:20.000-00:25.000"), text)
        XCTAssertTrue(text.contains("--apply"), text)

        let done = try h.service.restore(RestoreRequest(from: "1", clips: ["clip_brl1", "clip_mus1"], apply: true), context: h.context)
        XCTAssertEqual(done.applied?.revision, 4)
        let project = h.service.coordinator.project
        XCTAssertEqual(project.clip("clip_brl1"), original.clip("clip_brl1"))
        XCTAssertEqual(project.track(containingClip: "clip_brl1")?.id, "trk_broll")
        XCTAssertEqual(project.clip("clip_mus1"), original.clip("clip_mus1"))
        XCTAssertEqual(h.service.coordinator.undoLabel, "Restore 2 clips from revision 1")
        _ = try h.service.undo(expectedRevision: 4)
        XCTAssertNil(h.service.coordinator.project.clip("clip_brl1"), "one undo takes the whole restore back")
    }

    func testRestoreATimeRangeOnATrackTakesOutWhatReplacedIt() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(
            .removeClips(clipIDs: ["clip_brl1"]),
            .insertClip(trackID: "trk_broll", clip: Clip(id: "clip_new", content: .media(mediaID: "med_broll"), start: t(19), duration: t(4))),
            .updateClip(clipID: "clip_mus1", patch: gain(-20)),
            label: "Swap the shot"
        )
        let done = try h.service.restore(RestoreRequest(from: "1", fromTime: t(20), toTime: t(25), track: "B-roll", apply: true), context: h.context)
        XCTAssertEqual(Set(done.items.map(\.action)), [.putBack, .remove])
        let project = h.service.coordinator.project
        XCTAssertNil(project.clip("clip_new"))
        XCTAssertNotNil(project.clip("clip_brl1"))
        XCTAssertEqual(project.clip("clip_mus1")?.audio?.gainDB, -20, "only the B-roll track")
    }

    func testRestoreFromASnapshotAndItsMistakes() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let snapshot = h.folder.file("v1.mp4.tandem")
        try ProjectFile.encoder().encode(ProjectFile.Envelope(revision: 0, project: h.service.coordinator.project)).write(to: snapshot)
        try h.apply(.updateClip(clipID: "clip_cam1", patch: .object(["video": .object(["transform": .object(["scale": .number(1)])])])), label: "Full frame")
        let done = try h.service.restore(RestoreRequest(from: snapshot.path, clips: ["clip_cam1"], apply: true), context: h.context)
        XCTAssertEqual(done.items.first?.details, ["scale 1 -> 0.5"])
        XCTAssertEqual(h.service.coordinator.project.clip("clip_cam1")?.video?.transform.scale, 0.5)

        assertServiceError(.badRequest) { _ = try h.service.restore(RestoreRequest(from: "1"), context: h.context) }
        assertServiceError(.notFound) { _ = try h.service.restore(RestoreRequest(from: "1", clips: ["clip_nope"]), context: h.context) }
    }

    // MARK: - clips

    func testClipsFiltersByTrackTimeAndMedia() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let camera = try h.service.clips(ClipsRequest(track: "Camera"))
        XCTAssertEqual(camera.clips.map(\.id), ["clip_cam1", "clip_cam2"])
        XCTAssertEqual(camera.clips.first?.track, "V2 Camera")
        XCTAssertEqual(try h.service.clips(ClipsRequest(track: "V2")).clips.map(\.id), ["clip_cam1", "clip_cam2"])
        XCTAssertEqual(try h.service.clips(ClipsRequest(track: "trk_camera")).clips.map(\.id), ["clip_cam1", "clip_cam2"])

        let range = try h.service.clips(ClipsRequest(from: t(21), to: t(24)))
        XCTAssertEqual(range.clips.map(\.id), ["clip_brl1", "clip_cam1", "clip_scr1", "clip_voc1", "clip_mus1"])

        XCTAssertEqual(try h.service.clips(ClipsRequest(media: "take1-camera.mov")).clips.map(\.id), ["clip_cam1", "clip_cam2", "clip_voc1", "clip_voc2"])
        XCTAssertEqual(try h.service.clips(ClipsRequest(media: "med_music")).clips.map(\.id), ["clip_mus1"])
        XCTAssertEqual(try h.service.clips(ClipsRequest(media: "music/bed.m4a")).clips.map(\.mediaID), ["med_music"])

        XCTAssertEqual(try h.service.clips(ClipsRequest(track: "Voice", ids: true)).readableText, "clip_voc1\nclip_voc2")
        let text = try h.service.clips(ClipsRequest(track: "B-roll")).readableText
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("clip_brl1") })
        XCTAssertTrue(line.contains("V3 B-roll") && line.contains("00:20.000-00:25.000") && line.contains("servers.mp4"), text)

        assertServiceError(.notFound) { _ = try h.service.clips(ClipsRequest(track: "Nope")) }
        assertServiceError(.notFound) { _ = try h.service.clips(ClipsRequest(media: "nope.mov")) }
    }
}

final class DiffMCPTests: XCTestCase {
    func testDiffAndClipsTools() async throws {
        let mcp = try MCPHarness()
        _ = try await mcp.tool(1, "apply", #"{"commands": [{"removeClips": {"clipIDs": ["clip_brl1"]}}], "label": "Lift"}"#)
        let diff = try await mcp.tool(2, "diff", #"{"since": 1}"#)
        let text = try XCTUnwrap(diff[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(text.contains("removed  clip_brl1"), text)
        let clips = try await mcp.tool(3, "clips", #"{"track": "Camera", "ids": true}"#)
        XCTAssertEqual(clips[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString, "clip_cam1\nclip_cam2")
        let restore = try await mcp.tool(4, "restore", #"{"from": "1", "clips": ["clip_brl1"], "apply": true}"#)
        let restored = try XCTUnwrap(restore[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(restored.contains("Applied as revision 3"), restored)
        await mcp.close()
    }
}
