import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tighten` and `pauses` listening to the take: every cut in a real pause
/// in the sound of every track that plays there, Mike's gaps kept from the
/// words' sound, and pauses with sound in them left alone and said where.
final class TightenSoundTests: XCTestCase {
    /// The voice's file, as heard: (start, end, dB under the speaker).
    /// Timeline time is file time up to 30 s.
    static let voice: [(Double, Double, Double)] = [
        (2.0, 3.0, 0),
        (3.2, 3.5, 20),      // someone off mic, 20 dB under (#11)
        (4.6, 5.9, 0),
        (7.5, 9.0, 0),
        (10.4, 11.6, 0),     // "Then" starts 0.2 s before the transcript says (#64)
        (13.2, 13.8, 0),
        (13.88, 14.42, 20),  // off mic again, filling the gap after "Done."
        (14.5, 15.0, 0),
        (16.6, 17.0, 0)
    ]
    static let breaths: [(Double, Double)] = [(16.1, 16.4)]
    /// The iPad's own recording: digital silence but for the app talking.
    static let app: [(Double, Double, Double)] = [(12.0, 12.8, 0)]

    static let transcript = Transcript(language: "en", engine: "fake", words: [
        TranscriptWord(text: "That's", start: t(2.0), end: t(2.4)),
        TranscriptWord(text: "it.", start: t(2.45), end: t(3.0)),
        TranscriptWord(text: "So", start: t(4.6), end: t(5.0)),
        TranscriptWord(text: "the", start: t(5.05), end: t(5.3)),
        // Ends 0.15 s before its sound does.
        TranscriptWord(text: "plan.", start: t(5.35), end: t(5.75)),
        // Starts 0.1 s after its sound does.
        TranscriptWord(text: "Now", start: t(7.6), end: t(8.0)),
        TranscriptWord(text: "we", start: t(8.05), end: t(8.3)),
        TranscriptWord(text: "build.", start: t(8.35), end: t(9.0)),
        TranscriptWord(text: "Then", start: t(10.6), end: t(11.0)),
        TranscriptWord(text: "test.", start: t(11.05), end: t(11.6)),
        TranscriptWord(text: "Done.", start: t(13.2), end: t(13.8)),
        TranscriptWord(text: "Okay.", start: t(14.5), end: t(15.0)),
        TranscriptWord(text: "Right.", start: t(16.6), end: t(17.0))
    ])

    static let ipad = MediaItem(id: "med_ipad", path: "source/ipad.wav", kind: .audio, role: .other, duration: t(64), hasVideo: false, hasAudio: true)

    private func harness(muteIPad: Bool = false) throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.media.append(Self.ipad)
        // The iPad's recording on its own track, cut with the take.
        project.audioTracks.insert(Track(id: "trk_ipad", kind: .audio, name: "iPad", clips: [
            Clip(id: "clip_ipad", name: "ipad", content: .media(mediaID: "med_ipad"), start: t(0), duration: t(30), sourceStart: t(0))
        ], muted: muteIPad, rippleMode: .cut), at: 1)
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try Self.write(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.voice, breaths: Self.breaths, room: true)
        try Self.write(to: h.folder.file("source/ipad.wav"), length: 64, words: Self.app, breaths: [], room: false)
        h.analysis.transcripts["med_camera"] = Self.transcript
        // The app's line isn't in any transcript, as on the video in #11.
        h.analysis.transcripts["med_ipad"] = Transcript(language: "en", engine: "fake", words: [])
        return h
    }

    /// Room rumble and hiss (or digital silence) with a buzz of harmonics
    /// where `words` says, and breaths as hiss, at 32 kHz.
    static func write(to url: URL, length: Double, words: [(Double, Double, Double)], breaths: [(Double, Double)], room: Bool) throws {
        let rate = 32_000.0
        let count = Int(length * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        var seed: UInt32 = 12_345
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        var rumble: Float = 0
        for i in 0..<count {
            rumble += (noise() - rumble) * 0.02
            data[i] = room ? rumble * 0.03 + noise() * 0.00009 : 0
        }
        func span(_ start: Double, _ end: Double) -> Range<Int> { Int(start * rate)..<min(count, Int(end * rate)) }
        func fade(_ i: Int, _ range: Range<Int>) -> Float {
            Float(min(1, Double(i - range.lowerBound) / (0.005 * rate), Double(range.upperBound - i) / (0.005 * rate)))
        }
        for (start, end, under) in words {
            let range = span(start, end)
            let gain = 0.08 * pow(10, -under / 20)
            for i in range {
                let t = Double(i) / rate
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                data[i] += Float(buzz * gain) * fade(i, range)
            }
        }
        for (start, end) in breaths {
            let range = span(start, end)
            var last: Float = 0
            for i in range {
                let white = noise()
                data[i] += (white - last) * 0.0008 * fade(i, range)
                last = white
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func cut(after word: String, in result: TightenResult, file: StaticString = #filePath, line: UInt = #line) throws -> PlannedCut {
        try XCTUnwrap(result.cuts.first { $0.pause.before.hasSuffix(word) }, "no cut after \(word): \(result.readableText)", file: file, line: line)
    }

    func testEveryCutIsInARealPauseAndNeverThroughSound() async throws {
        let h = try harness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertNil(plan.applied)
        XCTAssertFalse(plan.warnings.contains { $0.contains("Couldn't read") }, "\(plan.warnings)")

        // The voice off mic after "it.": the cut goes in the quiet after it.
        let offMic = try cut(after: "it.", in: plan)
        let heard = try XCTUnwrap(offMic.pause.sound?.heard.first)
        XCTAssertEqual(heard.start.seconds, 3.2, accuracy: 0.02)
        XCTAssertEqual(heard.end.seconds, 3.5, accuracy: 0.02)
        XCTAssertEqual(heard.tracks, ["Voice"])
        XCTAssertGreaterThanOrEqual(offMic.cut.start.seconds, 3.5)
        XCTAssertLessThanOrEqual(offMic.cut.end.seconds, 4.6 - 0.03 + 0.001)

        // Mike's 0.4 s between sentences, from the end of "plan."'s sound
        // (5.9, not the transcript's 5.75) to the start of "Now"'s (7.5,
        // not 7.6).
        let plan2 = try cut(after: "plan.", in: plan)
        let sound = try XCTUnwrap(plan2.pause.sound)
        XCTAssertEqual(sound.start.seconds, 5.9, accuracy: 0.011)
        XCTAssertEqual(sound.end.seconds, 7.5, accuracy: 0.011)
        let kept = (plan2.cut.start.seconds - 5.9) + (7.5 - plan2.cut.end.seconds)
        XCTAssertEqual(kept, 0.4, accuracy: 0.04, "\(plan2.cut)")
        XCTAssertGreaterThanOrEqual(kept, 0.4 - 0.011)

        // "Then" starts 0.2 s before the transcript says: the cut ends
        // before its sound, not before 10.6.
        let early = try cut(after: "build.", in: plan)
        XCTAssertLessThanOrEqual(early.cut.end.seconds, 10.4 - 0.03 + 0.001)

        // The app talking on the iPad track in the voice's gap: the cut
        // goes beside it, never through it.
        let device = try cut(after: "test.", in: plan)
        XCTAssertEqual(device.pause.sound?.heard.first?.tracks, ["iPad"])
        XCTAssertFalse(device.cut.overlaps(TimeRange(start: t(12.0), end: t(12.8))), "\(device.cut)")

        // A breath before "Right.": kept, and the cut is in the quiet
        // before it.
        let breath = try cut(after: "Okay.", in: plan)
        XCTAssertLessThanOrEqual(breath.cut.end.seconds, 16.1 - 0.03 + 0.001)

        // Off mic right across the gap after "Done.": left alone, with
        // where the sound is.
        XCTAssertFalse(plan.cuts.contains { $0.pause.before.hasSuffix("Done.") })
        let crowded = try XCTUnwrap(plan.skipped.first { $0.pause.before.hasSuffix("Done.") }, "\(plan.skipped)")
        XCTAssertTrue([.sound, .speech].contains(crowded.reason), "\(crowded.reason)")
        XCTAssertFalse(try XCTUnwrap(crowded.pause.sound).heard.isEmpty)
        let text = plan.readableText
        XCTAssertTrue(text.contains("Left 1 pause with sound in it alone (listen with tandem clip):\n  00:13.800-00:14.500  0.700s  "), text)
        XCTAssertTrue(text.contains("Done. | Okay. Right....  sound at 00:13.8"), text)
        XCTAssertTrue(text.contains("...we build. Then test. | Done. Okay. Right...., beside sound at 00:12.0"), text)

        // Every join judges clean, as check --cuts will.
        XCTAssertEqual(plan.cuts.count, 5, text)
        for planned in plan.cuts {
            XCTAssertEqual(planned.startEdge?.verdict, .clean, "\(planned.cut)")
            XCTAssertEqual(planned.endEdge?.verdict, .clean, "\(planned.cut)")
        }
        XCTAssertEqual(h.service.coordinator.project, before, "a dry run changes nothing")

        // Applied, it's one undo step, and check --cuts passes every join.
        let applied = try await h.service.tighten(TightenRequest(mike: true, apply: true), context: h.context)
        XCTAssertEqual(applied.cuts, plan.cuts)
        XCTAssertEqual(h.service.coordinator.revision, 2)
        let check = try await CheckRequest(from: t(0), to: t(20), cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(check.ok, "\(check.problems)")
        XCTAssertTrue(check.notes.isEmpty, "\(check.notes)")
        XCTAssertNotNil(h.service.coordinator.undo())
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    func testAMutedTrackIsntListenedTo() async throws {
        let h = try harness(muteIPad: true)
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        // Nothing is heard on the voice between "test." and "Done.", so the
        // cut runs through where the muted iPad's app talks.
        let device = try cut(after: "test.", in: plan)
        XCTAssertEqual(device.pause.sound?.heard, [])
        XCTAssertTrue(device.cut.overlaps(TimeRange(start: t(12.0), end: t(12.8))), "\(device.cut)")
    }

    func testPausesSaysWhatsInTheSound() async throws {
        let h = try harness()
        defer { h.close() }
        let result = try await PausesRequest(min: 0.5).run(on: h.service, context: h.context)
        let device = try XCTUnwrap(result.pauses.first { $0.before.hasSuffix("test.") })
        XCTAssertEqual(device.start, t(11.6))
        XCTAssertEqual(device.sound?.heard.first?.tracks, ["iPad"])
        let early = try XCTUnwrap(result.pauses.first { $0.before.hasSuffix("build.") })
        XCTAssertEqual(try XCTUnwrap(early.sound).end.seconds, 10.4, accuracy: 0.011)
        let text = result.readableText
        XCTAssertTrue(text.contains("heard as 1.600s, sound at 00:12."), text)
        XCTAssertTrue(text.contains(" on iPad"), text)
    }

    func testWithoutSoundToListenToTheTranscriptsGapsAreCutAndItSaysSo() async throws {
        // The fixture's files aren't there.
        let h = try ServiceHarness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertFalse(plan.cuts.isEmpty)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("Couldn't read the sound of take1-camera.mov, so pauses there were cut from the transcript's gaps alone") }, "\(plan.warnings)")
    }
}
