import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore
import TandemMedia
import TandemRender

/// Checking sound without ffmpeg, through the API: `loudness --from --to`
/// for the mix over time (and `--gains` for the render against the gain
/// lanes), `clip --tracks` for solo tracks and stems, and `assets show`.
/// The renderer is the fake one; MixLoudnessTests renders for real.
final class SoundCheckTests: XCTestCase {
    func testLoudnessRequestsReadFriendlyForms() throws {
        let request = try ServiceJSON.decodeRequest(LoudnessRequest.self, from: Data(#"{"from": "1:00", "to": 90, "step": "0.5", "tracks": "Music, SFX", "gains": true}"#.utf8))
        XCTAssertEqual(request.from, t(60))
        XCTAssertEqual(request.to, t(90))
        XCTAssertEqual(request.step, t(0.5))
        XCTAssertEqual(request.tracks, ["Music", "SFX"])
        XCTAssertEqual(request.gains, true)
        let listed = try ServiceJSON.decodeRequest(LoudnessRequest.self, from: Data(#"{"tracks": ["Voice"]}"#.utf8))
        XCTAssertEqual(listed.tracks, ["Voice"])
        XCTAssertNil(try ServiceJSON.decodeRequest(LoudnessRequest.self, from: Data("{}".utf8)).from)

        let clip = try ServiceJSON.decodeRequest(ClipRequest.self, from: Data(#"{"start": "0:10", "end": 20, "tracks": "Music", "audioOnly": true}"#.utf8))
        XCTAssertEqual(clip.tracks, ["Music"])
        XCTAssertEqual(clip.audioOnly, true)
    }

    func testLoudnessOverTimeMeasuresTheMixOrTheChosenTracks() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }

        let curve = try await h.service.loudness(LoudnessRequest(from: t(10), to: t(20), step: t(2.5)))

        let measured = try XCTUnwrap(renderer.measures.all.first)
        XCTAssertEqual(measured.range, TimeRange(start: t(10), end: t(20)))
        XCTAssertEqual(measured.step, t(2.5))
        XCTAssertEqual(measured.muted, [false, false, false], "the whole mix")
        XCTAssertNil(curve.tracks)
        let text = curve.readableText
        XCTAssertTrue(text.hasPrefix("The mix from 00:10.000 to 00:20.000, every 2.5 s, as the timeline plays it (export's master gain moves it all by the same amount)."), text)
        XCTAssertTrue(text.contains("  time        momentary   short-term  peak"), text)
        XCTAssertTrue(text.contains("00:12.500   -30.0 LUFS"), text)
        XCTAssertTrue(text.contains("silent"), text)
        XCTAssertFalse(text.contains("Speech is levelled to"), "the per-file report stays out of the way")

        // Track names in any case, or IDs; only those play.
        let music = try await h.service.loudness(LoudnessRequest(from: t(0), to: t(10), tracks: ["music", "trk_sfx"]))
        XCTAssertEqual(renderer.measures.all.last?.muted, [true, false, false])
        XCTAssertEqual(music.tracks, ["Music", "SFX"])
        XCTAssertTrue(music.readableText.hasPrefix("Music and SFX from 00:00.000 to 00:10.000, every 0.2 s"), music.readableText)

        do {
            _ = try await h.service.loudness(LoudnessRequest(from: t(0), to: t(10), tracks: ["Musik"]))
            XCTFail("no such track")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
            XCTAssertTrue(error.message.contains("Audio tracks: Voice, Music, SFX."), error.message)
        }
        do {
            _ = try await h.service.loudness(LoudnessRequest(tracks: ["Screen"]))
            XCTFail("video tracks are silent")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("Screen is a video track"), error.message)
        }
        do {
            _ = try await h.service.loudness(LoudnessRequest(from: t(20), to: t(10)))
            XCTFail("empty range")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "badRequest")
        }

        // Without a range or tracks it's the per-file report, as before.
        let report = try await h.service.loudness(LoudnessRequest())
        XCTAssertNil(report.curve)
        XCTAssertTrue(report.readableText.hasPrefix("Speech is levelled to"), report.readableText)
    }

    func testLongRangesAreMeasuredAndReadAsASummary() async throws {
        // A 46 minute take at 0.4 s used to be refused past 2,000 rows.
        XCTAssertEqual(try TandemService.loudnessStep(t(0.4), over: t(2760)), t(0.4))
        XCTAssertThrowsError(try TandemService.loudnessStep(t(0.1), over: t(4 * 3600))) { error in
            XCTAssertTrue((error as? ServiceError)?.message.contains("100000 rows") == true, "\(error)")
        }

        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let long = try await h.service.loudness(LoudnessRequest(from: t(0), to: t(1080), step: t(0.4)))
        XCTAssertEqual(long.curve?.points.count, 2701, "--json still has every point")
        let text = long.readableText
        XCTAssertTrue(text.contains("Integrated -30.5 LUFS"), text)
        XCTAssertFalse(text.contains("  time        momentary"), "2,701 rows is too many to read")
        XCTAssertTrue(text.contains("2701 rows: --json gives every one, and --over <dBFS> lists the stretches that peak over a level."), text)
        let sparkline = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("Short-term: ") })
        XCTAssertLessThanOrEqual(sparkline.count, 12 + 200, "the sparkline keeps to a readable width")
    }

    func testOverListsTheWindowsThatPeakOverALevelAsStretches() async throws {
        let points = [-3.0, 0.5, 1.2, -2, 0.1, nil, 2].enumerated().map { index, peak in
            LoudnessPoint(time: t(Double(index) * 0.4), momentaryLUFS: -20, shortTermLUFS: -20, peakDBFS: peak)
        }
        let curve = MixLoudness(start: t(0), end: t(2.4), step: t(0.4), points: points, integratedLUFS: -20, truePeakDBTP: 2.3)
        let peaks = TandemService.peaks(in: curve, over: 0)
        XCTAssertEqual(peaks.threshold, 0)
        XCTAssertEqual(peaks.windows, 4)
        // Neighbouring windows merge; each stretch runs edge to edge of its
        // 400 ms windows, kept inside the range.
        XCTAssertEqual(peaks.stretches.map(\.start), [t(0.2), t(1.4), t(2.2)])
        XCTAssertEqual(peaks.stretches.map(\.end), [t(1.0), t(1.8), t(2.4)])
        XCTAssertEqual(peaks.stretches.map(\.peakDBFS), [1.2, 0.1, 2])
        XCTAssertEqual(peaks.stretches.map(\.windows), [2, 1, 1])

        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await h.service.loudness(LoudnessRequest(from: t(0), to: t(10), over: -20))
        XCTAssertEqual(renderer.measures.all.last?.step, t(0.4), "without --step the windows tile the range, so no sample goes unchecked")
        let found = try XCTUnwrap(result.peaks)
        XCTAssertEqual(found.windows, 25)
        XCTAssertEqual(found.stretches.count, 1)
        let text = result.readableText
        XCTAssertTrue(text.contains("25 windows peak over -20.0 dBFS, in 1 stretch:"), text)
        XCTAssertTrue(text.contains("  00:00.000-00:09.800  peak -12.0 dBFS (25 windows)"), text)
        XCTAssertFalse(text.contains("  time        momentary"), "the stretches are the answer")

        let quiet = try await h.service.loudness(LoudnessRequest(from: t(0), to: t(10), over: -1))
        XCTAssertTrue(quiet.readableText.contains("No window peaks over -1.0 dBFS."), quiet.readableText)
    }

    func testGainsCompareEachPlayingTrackWithItsLane() async throws {
        var renderer = FakeRenderer()
        renderer.gainChecks = [
            GainFollow(trackID: "trk_voice", track: "Voice", compared: 9.5, lateBy: nil, worstDB: 0.2, mismatches: []),
            GainFollow(trackID: "trk_music", track: "Music", compared: 10, lateBy: 0.15, worstDB: 9.8, mismatches: [
                GainMismatch(start: t(4.0), end: t(4.15), expectedDB: -21, measuredDB: -31)
            ])
        ]
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }

        let result = try await h.service.loudness(LoudnessRequest(from: t(0), to: t(10), gains: true))

        XCTAssertEqual(renderer.gainRequests.all.first?.trackIDs, ["trk_voice", "trk_music"], "the tracks that play there; SFX is empty")
        let text = result.readableText
        XCTAssertTrue(text.contains("Gain lanes against the render, 00:00.000 to 00:10.000:"), text)
        XCTAssertTrue(text.contains("  Voice  follows its lane (9.5 s compared, within 0.2 dB)"), text)
        XCTAssertTrue(text.contains("  Music  lands 150 ms late"), text)
        XCTAssertTrue(text.contains("    00:04.000-00:04.150  the lane says -21.0 dB, the render plays -31.0 dB"), text)
    }

    func testClipWithTracksRendersOnlyThoseUnmastered() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }

        let stem = try await h.service.prepareClip(ClipRequest(start: t(10), end: t(20), tracks: ["Music"]))()

        let export = try XCTUnwrap(renderer.exports.all.first)
        XCTAssertEqual(export.muted, [true, false, true])
        XCTAssertNil(export.preset.loudnessTarget, "a stem keeps the timeline's level")
        XCTAssertNil(export.preset.truePeakCeiling)
        XCTAssertEqual(URL(fileURLWithPath: stem.path).lastPathComponent, "review 00.10.000-00.20.000 Music.mp4")
        XCTAssertEqual(stem.tracks, ["Music"])
        XCTAssertTrue(stem.readableText.contains("Only Music plays, at the timeline's own level (not mastered)."), stem.readableText)

        let sound = try await h.service.prepareClip(ClipRequest(start: t(10), end: t(20), tracks: ["Voice", "SFX"], audioOnly: true))()
        XCTAssertEqual(URL(fileURLWithPath: sound.path).lastPathComponent, "review 00.10.000-00.20.000 Voice+SFX.m4a")
        XCTAssertNil(sound.width, "no picture")
        XCTAssertTrue(sound.readableText.hasPrefix("Wrote \(sound.path) (Review 720p, sound only,"), sound.readableText)

        let mix = try await h.service.prepareClip(ClipRequest(start: t(10), end: t(20), output: "mix.wav"))()
        XCTAssertNil(mix.width, "a .wav is sound alone")
        XCTAssertEqual(renderer.exports.all.last?.preset.loudnessTarget, -14, "the whole mix is mastered as before")

        XCTAssertThrowsError(try h.service.prepareClip(ClipRequest(start: t(10), end: t(20), output: "x.mp4", audioOnly: true))) { error in
            XCTAssertTrue((error as? ServiceError)?.message.contains(".m4a or .wav") == true, "\(error)")
        }
    }

    func testAssetsShowGivesTheLibrarysRecord() async throws {
        let h = try await AssetHarness(secrets: ["elevenlabs": "k"])
        h.transport.on("api.elevenlabs.io/v1/sound-generation", body: AssetFixtures.pcm)
        let made = try await h.service.generate(AssetGenerateRequest(kind: .sfx, prompt: "Short soft click", duration: 0.5))
        let asset = try XCTUnwrap(made.assets.first)

        let shown = try await h.service.show(AssetShowRequest(id: asset.id))

        XCTAssertEqual(shown.asset.id, asset.id)
        XCTAssertEqual(shown.prompt, "Short soft click")
        let file = try XCTUnwrap(shown.file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file), file)
        let text = shown.readableText
        XCTAssertTrue(text.hasPrefix("\(asset.id)  sfx, 0.50 s, ready"), text)
        XCTAssertTrue(text.contains("Prompt: Short soft click"), text)
        XCTAssertTrue(text.contains("Provider: elevenlabs"), text)
        XCTAssertTrue(text.contains("Loudness: "), text)
        XCTAssertTrue(text.contains("LUFS"), text)
        XCTAssertTrue(text.contains("Licence: "), text)
        XCTAssertTrue(text.contains("File: \(file)"), text)

        // An imported file not fetched yet: its folder's licence, and the
        // file where it sits in the import folder.
        let whooshID = try h.whoosh().id
        let unfetched = try await h.service.show(AssetShowRequest(id: whooshID))
        XCTAssertTrue(unfetched.readableText.contains("Licence: no credit"), unfetched.readableText)
        XCTAssertNil(unfetched.prompt)
        _ = try await h.service.fetch(AssetFetchRequest(id: whooshID))
        let whoosh = try await h.service.show(AssetShowRequest(id: whooshID))
        XCTAssertTrue(whoosh.readableText.contains("Licence: Mixkit Free License (no credit)"), whoosh.readableText)

        do {
            _ = try await h.service.show(AssetShowRequest(id: "noto:zzzz"))
            XCTFail("unknown asset")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
        }
    }

    func testMCPOffersTheNewOptions() async throws {
        let mcp = try MCPHarness()
        let list = try await mcp.call(1, "tools/list")
        let tools = try XCTUnwrap(list[json: "result"]?[json: "tools"]?.testArray)
        func properties(_ name: String) -> JSONValue? {
            tools.first { $0[json: "name"] == .string(name) }?[json: "inputSchema"]?[json: "properties"]
        }
        for key in ["from", "to", "step", "tracks", "gains", "over"] {
            XCTAssertNotNil(properties("loudness")?[json: key], key)
        }
        XCTAssertNotNil(properties("clip")?[json: "tracks"])
        XCTAssertNotNil(properties("clip")?[json: "audioOnly"])
        XCTAssertNotNil(properties("assets_show")?[json: "id"])

        let curve = try await mcp.tool(2, "loudness", #"{"from": "0:01", "to": 3, "tracks": "Music"}"#)
        let text = try XCTUnwrap(curve[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(text.hasPrefix("Music from 00:01.000 to 00:03.000"), text)
        await mcp.close()
    }
}

/// The options through the built `tandem`, rendering for real. The
/// fixture's files don't exist, so the mix is silent.
final class SoundCheckCLITests: XCTestCase {
    func testLoudnessClipAndAssetsShowFromTheCommandLine() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let cli = CLITests()
        let folder = TempFolder("tandem-sound-cli")
        _ = try APIFixture.write(to: folder.url)

        let curve = try cli.tandem("loudness", "--from", "0:01", "--to", "0:02", "--tracks", "Music", in: folder.url)
        XCTAssertEqual(curve.status, 0, curve.stderr)
        XCTAssertTrue(curve.stdout.hasPrefix("Music from 00:01.000 to 00:02.000, every 0.1 s"), curve.stdout)
        XCTAssertTrue(curve.stdout.contains("00:01.500   silent"), curve.stdout)

        let gains = try cli.tandem("loudness", "--from", "1", "--to", "2", "--gains", "--json", in: folder.url)
        XCTAssertEqual(gains.status, 0, gains.stderr)
        let result = try ServiceJSON.decoder().decode(LoudnessResult.self, from: Data(gains.stdout.utf8))
        XCTAssertEqual(result.gains?.map(\.track), ["Voice", "Music"])
        XCTAssertEqual(result.curve?.points.count, 11)

        let over = try cli.tandem("loudness", "--from", "0", "--to", "0:02", "--over", "-1", in: folder.url)
        XCTAssertEqual(over.status, 0, over.stderr)
        XCTAssertTrue(over.stdout.contains("No window peaks over -1.0 dBFS."), over.stdout)
        let badLevel = try cli.tandem("loudness", "--over", "loud", in: folder.url)
        XCTAssertEqual(badLevel.status, 2, badLevel.stderr)

        let wrong = try cli.tandem("loudness", "--tracks", "Musik", in: folder.url)
        XCTAssertEqual(wrong.status, 1)
        XCTAssertTrue(wrong.stderr.contains("Audio tracks: Voice, Music, SFX."), wrong.stderr)

        let help = try cli.tandem("help", "clip", in: folder.url)
        XCTAssertTrue(help.stdout.contains("--audio-only"), help.stdout)
        let badOption = try cli.tandem("frame", "1", "--tracks", "Music", in: folder.url)
        XCTAssertEqual(badOption.status, 2)

        let root = folder.url.appendingPathComponent("library", isDirectory: true)
        let env = ["TANDEM_ASSETS_ROOT": root.path, "TANDEM_ASSETS_OFFLINE": "1"]
        let missing = try cli.tandem("assets", "show", "noto:zzzz", in: folder.url, env: env)
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.stderr.contains("No asset noto:zzzz in the library"), missing.stderr)
        let noID = try cli.tandem("assets", "show", in: folder.url, env: env)
        XCTAssertEqual(noID.status, 2)
    }
}
