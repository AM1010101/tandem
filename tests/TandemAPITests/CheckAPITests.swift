import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem check` through the service: what it checks, what it reports.
final class CheckAPITests: XCTestCase {
    /// Grey frames at 30 fps from `start`, with a flat white flash at `flash`.
    private func frames(from start: Double, to end: Double, flash: Double? = nil) -> [FrameStats] {
        stride(from: start, to: end - 0.0001, by: 1.0 / 30).map { seconds in
            let lit = flash.map { abs($0 - seconds) < 0.001 } ?? false
            return FrameStats(
                time: Time(seconds: seconds), luma: lit ? 1 : 0.4, brightestTile: lit ? 1 : 0.4,
                flatGreen: 0, flatWhite: lit ? 1 : 0, thumbnail: [UInt8](repeating: lit ? 255 : 100, count: 16)
            )
        }
    }

    func testAFlashInTheFramesIsAProblem() async throws {
        var renderer = FakeRenderer()
        renderer.scanned = frames(from: 0, to: 2, flash: 1)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(from: t(0), to: t(2)).run(on: h.service, context: h.context)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.frames, 60)
        XCTAssertEqual(result.problems.map(\.kind), [.whiteBlock])
        XCTAssertEqual(result.problems.first?.start, t(1))
        let text = result.readableText
        XCTAssertTrue(text.hasPrefix("Checked 00:00.000-00:02.000 (60 frames) in "), text)
        XCTAssertTrue(text.contains("1 problem:"), text)
        XCTAssertTrue(text.contains("White block"), text)
        XCTAssertTrue(text.contains("On: clip_cam1 take1-camera"), "names the clips on screen, top first: \(text)")
    }

    /// Grey frames at 30 fps, one of them lighter at `flash`: not white,
    /// just unlike its neighbours, like the preview jumping for a frame.
    private func flicker(from start: Double, to end: Double, at flash: Double) -> [FrameStats] {
        stride(from: start, to: end - 0.0001, by: 1.0 / 30).map { seconds in
            let lit = abs(flash - seconds) < 0.001
            return FrameStats(time: Time(seconds: seconds), luma: 0.4, brightestTile: 0.4, flatGreen: 0, flatWhite: 0, thumbnail: [UInt8](repeating: lit ? 160 : 100, count: 16))
        }
    }

    func testAFlickerInTheScreenRecordingComesWithTheHoldThatFixesIt() async throws {
        var renderer = FakeRenderer()
        renderer.scanned = flicker(from: 0, to: 2, at: 1)
        renderer.screenScanned = flicker(from: 0, to: 2, at: 1)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(from: t(0), to: t(2)).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.map(\.kind), [.flicker])
        let flash = TimeRange(start: t(1), end: t(1) + FrameRate.fps30.frameDuration)
        let hold = EditCommand.holdFrame(clipID: "clip_scr1", range: flash)
        XCTAssertEqual(result.problems.first?.fix, hold, "the screen recording flashes on its own, under the camera")
        XCTAssertEqual(result.commands, [hold])
        XCTAssertEqual(result.revision, h.service.coordinator.revision)
        let text = result.readableText
        XCTAssertTrue(text.contains("Hold the frame before it: holdFrame on clip_scr1."), text)
        XCTAssertTrue(text.contains(#"Fix: tandem apply --expect \#(h.service.coordinator.revision) --label "Hold the frame before each flicker" '[{"holdFrame":"#), text)
        let json = String(decoding: try ServiceJSON.encoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains(#""commands":[{"holdFrame""#), json)

        _ = try h.service.apply(ApplyRequest(label: QualityCheck.holdLabel, commands: result.commands, expectedRevision: result.revision), context: h.context)
        let screen = try XCTUnwrap(h.service.coordinator.project.track(named: "Screen")).clips
        XCTAssertEqual(screen.filter(\.freezeFrame).map(\.range), [flash])
        XCTAssertEqual(h.service.coordinator.project.track(named: "Voice")?.clips.first?.range, TimeRange(start: t(0), end: t(30)), "the sound plays on uncut")
    }

    func testTheNextCheckOnlyRendersThePiecesThatChanged() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let first = try await CheckRequest(from: t(0), to: t(40)).run(on: h.service, context: h.context)
        XCTAssertEqual(renderer.scans.all.filter { !$0.screen }.map(\.ranges), [[TimeRange(start: .zero, end: t(40))]])

        let again = try await CheckRequest(from: t(0), to: t(40)).run(on: h.service, context: h.context)
        XCTAssertEqual(renderer.scans.all.count, 2, "nothing changed, so nothing is rendered again")
        XCTAssertEqual(again.frames, first.frames)
        XCTAssertEqual(again.problems, first.problems)
        XCTAssertEqual(again.notes, first.notes)

        // The B-roll at 20 to 25 moves a second later: the pieces from 10 to
        // 30 (with the margin either side for transitions) render again.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false))
        _ = try await CheckRequest(from: t(0), to: t(40)).run(on: h.service, context: h.context)
        XCTAssertEqual(renderer.scans.all.dropFirst(2).filter { !$0.screen }.map(\.ranges), [[TimeRange(start: t(10), end: t(30))]])
    }

    func testCachedFramesReadBackExactly() throws {
        let frames = [
            FrameStats(time: t(1.5), luma: 0.123456789, brightestTile: 0.9, flatGreen: 0.01, flatWhite: 0.2, thumbnail: [1, 2, 3, 4], columns: 2, scanlines: [9, 8, 7]),
            FrameStats(time: t(1.533), luma: 0, brightestTile: 0, flatGreen: 0, flatWhite: 0, thumbnail: [], columns: 1)
        ]
        XCTAssertEqual(CheckCache.decode(CheckCache.encode(frames)), frames)
        XCTAssertNil(CheckCache.decode(CheckCache.encode(frames).dropLast()), "a cut-short file isn't read")
    }

    /// Still 32 x 18 frames at 30 fps from `start`, and with `turn` a new
    /// page from then on, as the screen recording on its own shows it.
    private func pages(from start: Double, to end: Double, turn: Double? = nil) -> [FrameStats] {
        stride(from: start, to: end - 0.0001, by: 1.0 / 30).map { seconds in
            let page = turn.map { seconds >= $0 - 0.0001 ? 1 : 0 } ?? 0
            let tiles = (0..<(32 * 18)).map { (tile: Int) -> UInt8 in UInt8(20 + (tile * (page + 3) + page * 11) % 7 * 6) }
            return FrameStats(time: Time(seconds: seconds), luma: 0.1, brightestTile: 0.2, flatGreen: 0, flatWhite: 0, thumbnail: tiles, columns: 32)
        }
    }

    func testDeadAirAndPageChangesAreNotes() async throws {
        var renderer = FakeRenderer()
        renderer.scanned = pages(from: 0, to: 9)
        renderer.screenScanned = pages(from: 0, to: 9, turn: 8)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(from: t(0), to: t(9)).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "notes don't fail a check")
        XCTAssertEqual(result.notes.map(\.kind), [.deadAir, .pageChange])
        let dead = try XCTUnwrap(result.notes.first)
        XCTAssertEqual(dead.start, t(3.6), "the 1.4 s pause after \"decision models.\"; the 0.7 s one isn't")
        XCTAssertEqual(dead.end, t(5.0))
        XCTAssertEqual(result.notes.last?.start, t(8))
        XCTAssertEqual(renderer.scans.all.count, 2)
        XCTAssertEqual(Set(renderer.scans.all.map(\.screen)), [false, true], "the composite and the screen recording on its own")
        XCTAssertEqual(renderer.scans.all.first { $0.screen }?.ranges, [TimeRange(start: .zero, end: t(9))])

        let text = result.readableText
        XCTAssertTrue(text.contains("no problems."), text)
        XCTAssertTrue(text.contains("Notes (not problems):\n  00:03.600-00:05.000  Dead air: 1.40 s with nothing said, no sound effect or music swell, and a still picture (after \"talk about decision models.\"). Cut it, or keep it if the pause earns it.  On: clip_txt1 title \"DECISION MODELS\", clip_cam1 take1-camera, clip_scr1 take1-screen"), text)
        XCTAssertTrue(text.contains("00:08.000-00:08.033  Page change inside a clip, with no transition: "), text)
        let json = String(decoding: try ServiceJSON.encoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains(#""kind":"deadAir""#) && json.contains(#""kind":"pageChange""#), json)
    }

    func testChangedChecksDeadAirAndPagesWhereThingsChanged() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        // An agent moves the B-roll to 21 to 26, where nothing is said.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false))
        let result = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        let changed = TimeRange(start: t(20.5), end: t(26.5))
        XCTAssertEqual(renderer.scans.all.map(\.ranges), [[changed], [changed]], "both scans read only what changed")
        XCTAssertEqual(result.notes.map(\.kind), [.deadAir])
        XCTAssertEqual(result.notes.first.map { TimeRange(start: $0.start, end: $0.end) }, changed)
    }

    func testNoTranscriptMeansNoDeadAirAndSaysSo() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts = [:]
        let result = try await CheckRequest(from: t(0), to: t(9)).run(on: h.service, context: h.context)
        XCTAssertTrue(result.notes.isEmpty, "the voice could be saying anything: \(result.notes)")
        XCTAssertEqual(result.warnings, ["No transcript yet for take1-camera.mov, so dead air isn't checked where it plays."])
        XCTAssertTrue(result.readableText.contains("Warning: No transcript yet for take1-camera.mov"), result.readableText)
    }

    func testAQuickCheckRendersNothing() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(renderer.scans.all.isEmpty, "not even the screen recording")
        XCTAssertTrue(result.warnings.isEmpty, "a quick check doesn't look for dead air, so it can't miss any")
        XCTAssertEqual(result.frames, 0)
        XCTAssertEqual(result.ranges, [TimeRange(start: .zero, end: t(60))])
        XCTAssertTrue(result.ok, "\(result.problems)")
        XCTAssertTrue(result.readableText.contains("(quick: no frames rendered)"), result.readableText)
    }

    func testChangedChecksWhatsWaitingForReview() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let nothing = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        XCTAssertTrue(nothing.ranges.isEmpty)
        XCTAssertEqual(nothing.readableText, "Nothing is waiting for Mike's review, so there was nothing to check.")

        // An agent moves the B-roll to 21 to 26.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false))
        let changed = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        XCTAssertEqual(changed.ranges, [TimeRange(start: t(20.5), end: t(26.5))], "the change and half a second either side")
        XCTAssertEqual(changed.frames, 180)
    }

    func testABlownUpPictureIsANoteNotAProblem() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.updateMedia(mediaID: "med_broll", patch: .object(["width": .number(1280), "height": .number(720)])))
        try h.apply(.updateClip(clipID: "clip_brl1", patch: .object(["video": .object(["transform": .object(["scale": .number(1.5)])])])))
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "notes don't fail a check")
        XCTAssertEqual(result.notes.map(\.kind), [.soft])
        XCTAssertTrue(result.readableText.contains("Notes (not problems):"), result.readableText)
    }

    func testClipsAndGapsShorterThanAFrameAreSliverNotes() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        func solid(_ id: String, _ start: Double, _ duration: Double) -> EditCommand {
            .insertClip(trackID: "trk_broll", clip: Clip(id: id, content: .solid(color: .black), start: t(start), duration: t(duration)))
        }
        try h.apply(solid("clip_a", 26, 1), solid("clip_b", 27.01, 1), solid("clip_tiny", 29, 0.02))
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "notes don't fail a check")
        let slivers = result.notes.filter { $0.kind == .sliver }
        XCTAssertEqual(slivers.map(\.start), [t(27), t(29)])
        XCTAssertEqual(slivers.map(\.end), [t(27.01), t(29.02)])
        XCTAssertEqual(slivers.map(\.clipIDs), [["clip_a", "clip_b"], ["clip_tiny"]])
        let text = result.readableText
        XCTAssertTrue(text.contains("00:27.000-00:27.010  Sliver: a 0.010 s gap between clips on \"B-roll\", under a frame at 30 fps."), text)
        XCTAssertTrue(text.contains("00:29.000-00:29.020  Sliver: a 0.020 s clip on \"B-roll\", under a frame at 30 fps."), text)

        let narrow = try await CheckRequest(from: t(0), to: t(28), quick: true).run(on: h.service, context: h.context)
        XCTAssertEqual(narrow.notes.filter { $0.kind == .sliver }.map(\.start), [t(27)], "only what's in the checked stretch")
    }

    func testRequestsThatDontMakeSenseAreRefused() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        for request in [CheckRequest(from: t(10), to: t(5)), CheckRequest(from: t(1), changed: true), CheckRequest(width: 10), CheckRequest(quick: true, cuts: true)] {
            do {
                _ = try await request.run(on: h.service, context: h.context)
                XCTFail("\(request) should be refused")
            } catch let error as ServiceError {
                XCTAssertEqual(error.code, "badRequest")
            }
        }
    }

    // MARK: - Cuts

    /// The camera's sound as a 16 kHz WAV: room noise, with "words" (a buzz
    /// of harmonics) where `words` says, in file time, and `soft` ones some
    /// dB under them: (start, end, dB).
    private func writeVoice(to url: URL, length: Double, words: [(Double, Double)], soft: [(Double, Double, Double)] = []) throws {
        let rate = 16_000.0
        let count = Int(length * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        var seed: UInt32 = 7
        var rumble: Float = 0
        for i in 0..<count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            rumble += (Float(Int32(bitPattern: seed)) / Float(Int32.max) - rumble) * 0.04
            data[i] = rumble * 0.03
        }
        for (start, end, under) in words.map({ ($0.0, $0.1, 0.0) }) + soft {
            let from = Int(start * rate), to = Int(end * rate)
            let gain = 0.08 * pow(10, -under / 20)
            for i in from..<to {
                let t = Double(i) / rate
                let fade = min(1, Double(i - from) / 80, Double(to - i) / 80)
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                data[i] += Float(buzz * gain * fade)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// The fixture with the camera's sound in a WAV file that's really there.
    private func voicedHarness(words: [(Double, Double)], soft: [(Double, Double, Double)] = []) throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: words, soft: soft)
        return h
    }

    func testAWordRunningPastACutIsAProblemWithItsFix() async throws {
        // "section." runs on 0.12 s past file time 30, where the first piece
        // of the take ends; "Now" starts well after the second piece does (32).
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 30.12), (30.5, 31.4), (32.3, 32.8)])
        defer { h.close() }
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.frames, 0, "nothing rendered")
        XCTAssertEqual(result.cuts, 4, "the take's start, the cut at 30 (both sides) and its end")
        XCTAssertEqual(result.problems.map(\.kind), [.clippedWord])
        let problem = try XCTUnwrap(result.problems.first)
        XCTAssertEqual(problem.start, t(30))
        XCTAssertEqual(problem.clipIDs, ["clip_voc1", "clip_voc2"])
        let cut = try XCTUnwrap(problem.cut)
        XCTAssertEqual(cut.clipID, "clip_voc1")
        XCTAssertEqual(cut.edge, .end)
        XCTAssertEqual(cut.fixKind, .trimToPause)
        XCTAssertLessThan(try XCTUnwrap(cut.margin), 9, "cut while the word's sounding")
        // Just into the pause after the word (30.16), on a frame.
        let to = t(30) + Time.frames(5, at: .fps30)
        XCTAssertEqual(cut.to, to)
        let fix = EditCommand.trim(clipID: "clip_voc1", edge: .end, to: to, ripple: true, includeLinked: nil)
        XCTAssertEqual(result.commands, [fix])
        XCTAssertEqual(result.revision, h.service.coordinator.revision)

        let text = result.readableText
        XCTAssertTrue(text.hasPrefix("Checked 00:00.000-01:00.000 (4 cut edges) in "), text)
        XCTAssertTrue(text.contains("  00:30.000  Clipped word at the end of clip_voc1: the voice runs on 0.12 s past the cut; the clip's last 25 ms is 1.2 dB under the speech. Trim the end 0.167 s later, into the pause after it.  On: clip_voc1 take1-camera, clip_voc2 take1-camera"), text)
        XCTAssertTrue(text.contains("Fix: tandem apply --expect \(result.revision ?? 0) --label \"Move clipped cuts into pauses\" '[{\"trim\":"), text)

        // Applying the fix leaves nothing to find.
        try h.service.apply(ApplyRequest(label: "fix", commands: result.commands), context: h.context)
        let again = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(again.ok, "\(again.problems)")
        XCTAssertTrue(again.commands.isEmpty)
    }

    func testACutWhoseOnlyPauseIsPastACutWordIsPutBack() async throws {
        // "that because": "that" is kept and runs straight into "because",
        // cut with the 2 s after it. The pause after "because" is in reach,
        // but trimming into it brings "because" back.
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 30.25), (33, 33.8)])
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "that", start: t(29.5), end: t(30)),
            TranscriptWord(text: "because", start: t(30.02), end: t(30.24)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.map(\.kind), [.clippedWord])
        let cut = try XCTUnwrap(result.problems.first?.cut)
        XCTAssertEqual(cut.fixKind, .putBack)
        XCTAssertNil(cut.to)
        let fix = EditCommand.trim(clipID: "clip_voc1", edge: .end, to: t(32), ripple: true, includeLinked: nil)
        XCTAssertEqual(cut.fix, fix, "the end of the first piece on to where the second starts in the take")
        XCTAssertEqual(result.commands, [fix])
        XCTAssertTrue(result.readableText.contains("No pause it can reach without bringing back a cut word: put back the 2.00 s cut here, filler and all (the end of clip_voc1 2.000 s later)."), result.readableText)

        // Put back, the take carries straight on: nothing left to check there.
        try h.service.apply(ApplyRequest(label: "fix", commands: result.commands), context: h.context)
        let again = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(again.ok, "\(again.problems)")
        XCTAssertEqual(again.cuts, 2, "the take's start and end")

        // Without the transcript, nothing says "because" is a word, so the
        // trim goes into the pause.
        XCTAssertNotNil(h.service.coordinator.undo())
        h.analysis.transcripts["med_camera"] = nil
        let unheard = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(unheard.problems.first?.cut?.fixKind, .trimToPause)
    }

    func testAMarginalJoinIsANote() async throws {
        // The first piece's last 30 ms trail off 12 dB under the speech, and
        // what's cut after them is the rest of that soft tail, then a pause:
        // nothing at speech level is cut off, so only the level says how it
        // sounds. (A cut word running on past the cut would clip it.)
        let h = try voicedHarness(words: [(1, 3.6), (29, 29.97), (33, 33.8)], soft: [(29.97, 30.1, 12)])
        defer { h.close() }
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "marginal doesn't fail: \(result.problems)")
        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertEqual(result.notes.map(\.kind), [.marginalJoin])
        let cut = try XCTUnwrap(result.notes.first?.cut)
        XCTAssertEqual(cut.clipID, "clip_voc1")
        XCTAssertEqual(try XCTUnwrap(cut.margin), 12, accuracy: 2)
        XCTAssertNil(cut.fixKind)
        XCTAssertNil(cut.fix)
        let text = result.readableText
        XCTAssertTrue(text.contains("no problems.\nNotes (not problems):\n  00:30.000  Marginal join at the end of clip_voc1: the clip's last 25 ms is "), text)
        XCTAssertTrue(text.contains(" dB under the speech (clean is 15 or more, clipped under 9). Listen to it with tandem clip.  On: clip_voc1 take1-camera, clip_voc2 take1-camera"), text)
    }

    func testCutsInPausesAreFine() async throws {
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 29.9), (32.3, 32.8)])
        defer { h.close() }
        let result = try await CheckRequest(from: t(25), to: t(35), cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "\(result.problems)")
        XCTAssertEqual(result.cuts, 2, "only the cut in the stretch checked")
        XCTAssertTrue(result.readableText.contains("no problems."), result.readableText)
    }

    func testCutsWithNoSoundToReadSaySo() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.warnings, ["Couldn't read the sound of take1-camera.mov, so its cuts weren't checked."])
    }

    func testTheRequestReadsFriendlyTimes() throws {
        let request = try ServiceJSON.decodeRequest(CheckRequest.self, from: Data(#"{"from": "5:40", "to": 371, "quick": true, "cuts": true}"#.utf8))
        XCTAssertEqual(request.from, t(340))
        XCTAssertEqual(request.to, t(371))
        XCTAssertEqual(request.quick, true)
        XCTAssertEqual(request.cuts, true)
    }
}
