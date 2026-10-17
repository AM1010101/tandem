import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Checking sound without ffmpeg: the mix's loudness over time, solo
/// tracks rendered on their own (as a file with no picture too), and a
/// check that the render follows the gain lanes. All read the mix the way
/// export does.
final class MixLoudnessTests: XCTestCase {
    static let rate = 48_000

    /// A stereo float WAV with `sample(i)` on both channels.
    @discardableResult
    func wav(_ media: TestMedia, _ name: String, seconds: Double, sample: (Int) -> Float) throws -> URL {
        let url = media.folder.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate), channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * Double(Self.rate))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let v = sample(i)
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        try file.write(from: buffer)
        return url
    }

    static func tone(_ hz: Double, peakDB: Double) -> (Int) -> Float {
        let peak = pow(10, peakDB / 20)
        return { i in Float(peak * sin(2 * Double.pi * hz * Double(i) / 48_000)) }
    }

    func keys(_ pairs: [(Double, Double)]) -> [Keyframe] {
        pairs.map { Keyframe(time: t($0.0), value: .number($0.1), interpolation: .linear) }
    }

    /// A 10 s tone on Voice that steps up 10 dB at 4 s, and a quieter one
    /// on Music from 2 s to 6 s.
    func twoTracks(_ media: TestMedia) throws -> Project {
        try wav(media, "voice.wav", seconds: 12, sample: Self.tone(1000, peakDB: -20))
        try wav(media, "music.wav", seconds: 12, sample: Self.tone(500, peakDB: -20))
        let voiceItem = MediaItem(id: "med_voice", path: "voice.wav", kind: .audio, role: .other, duration: t(12), hasAudio: true)
        let musicItem = MediaItem(id: "med_music", path: "music.wav", kind: .audio, role: .music, duration: t(12), hasAudio: true)
        var voice = Clip(id: "clip_voice", content: .media(mediaID: voiceItem.id), start: .zero, duration: t(10))
        voice.keyframes["audio.gainDB"] = keys([(3.95, 0), (4.05, 10)])
        var music = Clip(id: "clip_music", content: .media(mediaID: musicItem.id), start: t(2), duration: t(4))
        music.audio = AudioProperties(gainDB: -20)
        return smallProject(video: [], audio: [
            Track(id: "trk_voice", kind: .audio, name: "Voice", clips: [voice]),
            Track(id: "trk_music", kind: .audio, name: "Music", clips: [music], rippleMode: .follow)
        ], media: [voiceItem, musicItem])
    }

    func point(_ curve: MixLoudness, at seconds: Double, file: StaticString = #filePath, line: UInt = #line) throws -> LoudnessPoint {
        try XCTUnwrap(curve.points.first { abs($0.time.seconds - seconds) < 0.001 }, "no point at \(seconds)", file: file, line: line)
    }

    // MARK: - Loudness over time

    func testLoudnessOverTimeFollowsTheMix() async throws {
        let media = try TestMedia()
        let project = try twoTracks(media)
        let context = RenderContext(project: project, folder: media.projectFolder)

        let curve = try await MixMeter.measure(context, range: TimeRange(start: t(1), end: t(11)), step: t(0.5))

        XCTAssertEqual(curve.points.count, 21, "1 s to 11 s every 0.5 s, both ends")
        XCTAssertEqual(curve.points.first?.time, t(1))
        XCTAssertEqual(curve.points.last?.time, t(11))
        let before = try XCTUnwrap(try point(curve, at: 1.5).momentaryLUFS)
        let after = try XCTUnwrap(try point(curve, at: 8).momentaryLUFS)
        XCTAssertEqual(after - before, 10, accuracy: 0.3, "the voice steps up 10 dB")
        // Short-term is the 3 s centred on the time, so at 4 s it's half
        // way between the two levels' energies, and the step shows in
        // momentary (400 ms) at once.
        let step = try point(curve, at: 4.5).momentaryLUFS ?? -99
        XCTAssertEqual(step, after, accuracy: 0.5)
        let shortTerm = try XCTUnwrap(try point(curve, at: 4).shortTermLUFS)
        XCTAssertGreaterThan(shortTerm, before + 3)
        XCTAssertLessThan(shortTerm, after - 1)
        // The music 20 dB down adds a sliver of energy while it plays.
        XCTAssertNil(try point(curve, at: 10.5).momentaryLUFS, "silent after the voice ends at 10 s")
        let peak = try XCTUnwrap(try point(curve, at: 8).peakDBFS)
        XCTAssertEqual(peak, -10, accuracy: 0.2)
        let integrated = try XCTUnwrap(curve.integratedLUFS)
        XCTAssertGreaterThan(integrated, before)
        XCTAssertLessThan(integrated, after)
    }

    func testSoloingATrackMeasuresOnlyIt() async throws {
        let media = try TestMedia()
        let project = AudioLevels.soloing(try twoTracks(media), audioTrackIDs: ["trk_music"])
        XCTAssertEqual(project.audioTracks.map(\.muted), [true, false])
        let context = RenderContext(project: project, folder: media.projectFolder)

        let curve = try await MixMeter.measure(context, range: TimeRange(start: t(0), end: t(8)), step: t(1))

        XCTAssertNil(try point(curve, at: 1).momentaryLUFS, "Music starts at 2 s; Voice is muted")
        let music = try XCTUnwrap(try point(curve, at: 4).momentaryLUFS)
        XCTAssertNil(try point(curve, at: 7).momentaryLUFS, "Music ends at 6 s")
        // The same tone 20 dB down from the voice's first level: about -40
        // LUFS for a 500 Hz sine peaking at -40 dBFS on both channels.
        XCTAssertEqual(music, -40.7, accuracy: 1)
    }

    // MARK: - Audio-only renders

    func testAnAudioOnlyClipWritesTheMixWithoutAPicture() async throws {
        let media = try TestMedia()
        let project = AudioLevels.soloing(try twoTracks(media), audioTrackIDs: ["trk_voice"])
        let context = RenderContext(project: project, folder: media.projectFolder)
        for name in ["voice.m4a", "voice-stem.wav"] {
            let output = media.folder.appendingPathComponent("exports/\(name)")
            var preset = ExportPreset.review
            preset.range = TimeRange(start: t(3), end: t(5))
            preset.loudnessTarget = nil
            preset.truePeakCeiling = nil
            let result = try await Exporter(context: context, preset: preset, output: output).run()

            let asset = AVURLAsset(url: output)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertTrue(videoTracks.isEmpty, name)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 2, accuracy: 0.05, name)
            XCTAssertEqual(result.duration, t(2))
            // Left alone, not mastered: the voice before and after its step.
            let samples = try await decodeAudio(output)
            func peak(from: Double, to: Double) -> Double {
                let slice = samples[(Int(from * 48_000) * 2)..<(Int(to * 48_000) * 2)]
                return 20 * log10(Double(slice.map { abs($0) }.max() ?? 0))
            }
            XCTAssertEqual(peak(from: 0.2, to: 0.8), -20, accuracy: 0.3, name)
            XCTAssertEqual(peak(from: 1.3, to: 1.9), -10, accuracy: 0.3, name)
        }
    }

    func testExportRefusesOtherAudioFormats() async throws {
        let media = try TestMedia()
        let context = RenderContext(project: try twoTracks(media), folder: media.projectFolder)
        let output = media.folder.appendingPathComponent("voice.aiff")
        do {
            _ = try await Exporter(context: context, preset: .review, output: output).run()
            XCTFail("aiff isn't offered")
        } catch {
            XCTAssertTrue("\(error)".contains(".m4a or .wav"), "\(error)")
        }
    }

    // MARK: - Gain lanes against the render

    func testTheRenderFollowsItsGainLanes() async throws {
        let media = try TestMedia()
        var project = try twoTracks(media)
        // A slow dip and a fast rise on the music too.
        project.audioTracks[1].clips[0].keyframes["audio.gainDB"] = keys([(2.5, -20), (3.5, -35), (4.5, -35), (4.6, -15)])
        let context = RenderContext(project: project, folder: media.projectFolder)

        let checks = try await MixMeter.checkGains(context, range: TimeRange(start: t(1), end: t(9)), trackIDs: ["trk_voice", "trk_music"])

        XCTAssertEqual(checks.map(\.track), ["Voice", "Music"])
        for check in checks {
            XCTAssertTrue(check.mismatches.isEmpty, "\(check.track): \(check.mismatches)")
            XCTAssertNil(check.lateBy, check.track)
            XCTAssertLessThan(check.worstDB ?? 99, 0.5, check.track)
            XCTAssertGreaterThan(check.compared, 3, check.track)
        }
    }

    func testAGainChangeThatLandsLateIsCaught() {
        // Expected: 0 dB, a step to +10 dB at block 100. Heard: the step 15
        // blocks (150 ms) late, as AVAudioMix's ramps used to play it.
        let expected: [Double?] = (0..<300).map { $0 < 100 ? 0 : 10 }
        let heard: [Double?] = (0..<300).map { $0 < 115 ? 0 : 10 }

        let result = GainFollow.compare(expected: expected, measured: heard, start: 2, block: 0.01, tolerance: 1)

        XCTAssertEqual(result.lateBy ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(result.mismatches.count, 1)
        let miss = result.mismatches[0]
        XCTAssertEqual(miss.start.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(miss.end.seconds, 3.15, accuracy: 0.001)
        XCTAssertEqual(miss.expectedDB, 10)
        XCTAssertEqual(miss.measuredDB, 0)
        XCTAssertEqual(result.worst ?? 0, 10, accuracy: 0.001)

        let never = GainFollow.compare(expected: expected, measured: (0..<300).map { _ in 0 }, start: 0, block: 0.01, tolerance: 1)
        XCTAssertEqual(never.mismatches.first?.start.seconds ?? -1, 1, accuracy: 0.001, "a change that never lands")
        XCTAssertEqual(never.mismatches.first?.end.seconds ?? -1, 3, accuracy: 0.001)

        let fine = GainFollow.compare(expected: expected, measured: expected, start: 0, block: 0.01, tolerance: 1)
        XCTAssertNil(fine.lateBy)
        XCTAssertTrue(fine.mismatches.isEmpty)
    }
}
