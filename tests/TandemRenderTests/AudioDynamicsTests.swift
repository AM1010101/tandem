import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// The compressor, limiter and voice clean-up effects' processing, on
/// synthetic sound: what goes over the ceiling, what the ratio does, and
/// that nothing moves in time.
final class AudioDynamicsTests: XCTestCase {
    static let rate = 48_000.0

    /// Interleaved stereo sine at an RMS level in dBFS.
    func tone(rmsDB: Double, frequency: Double = 220, seconds: Double) -> [Float] {
        let amplitude = pow(10, rmsDB / 20) * 2.0.squareRoot()
        let frames = Int(seconds * Self.rate)
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / Self.rate))
            out[2 * i] = v
            out[2 * i + 1] = v
        }
        return out
    }

    /// RMS level in dBFS of the left channel between two times.
    func rms(_ samples: [Float], from: Double, to: Double) -> Double {
        let a = Int(from * Self.rate), b = Int(to * Self.rate)
        var sum = 0.0
        for i in a..<b { sum += Double(samples[2 * i]) * Double(samples[2 * i]) }
        return 10 * log10(sum / Double(b - a))
    }

    func peakDB(_ samples: [Float], from: Double = 0, to: Double? = nil) -> Double {
        let a = Int(from * Self.rate), b = to.map { Int($0 * Self.rate) } ?? samples.count / 2
        let peak = (a..<b).map { abs(samples[2 * $0]) }.max() ?? 0
        return 20 * log10(Double(peak))
    }

    func chain(_ effects: [Effect], levelDB: Double = 0) throws -> AudioEffectChain {
        try XCTUnwrap(AudioEffectChain(effects: effects, registry: .standard, channels: 2, levelDB: levelDB))
    }

    // MARK: - Limiter

    /// Speech-like bursts around -20 dBFS with transients 20 dB over them,
    /// the shape of Ian's mic once it's levelled.
    func burstsWithTransients() -> (signal: [Float], transients: [Double]) {
        var signal = tone(rmsDB: -20, seconds: 4)
        var transients: [Double] = []
        for at in [0.5, 1.3, 2.1, 2.9] {
            let start = Int(at * Self.rate)
            // A 5 ms click 20 dB over the bursts' peaks, then the bursts.
            for i in start..<(start + 240) {
                let v = Float(pow(10, (-17 + 20) / 20) * sin(2 * Double.pi * 1_500 * Double(i - start) / Self.rate))
                signal[2 * i] += v
                signal[2 * i + 1] += v
            }
            transients.append(at)
        }
        return (signal, transients)
    }

    func testTheLimiterHoldsTransientsTwentyDBOverUnderItsCeiling() throws {
        let (input, _) = burstsWithTransients()
        XCTAssertGreaterThan(peakDB(input), 2, "the clicks go over full scale")
        var limiter = try chain([Effect(type: "limiter", params: ["ceiling": .number(-1)])])
        let output = limiter.processAll(input)
        XCTAssertEqual(output.count, input.count)
        var meter = LoudnessMeter(sampleRate: Self.rate, channels: 2)
        meter.process(interleaved: output)
        XCTAssertLessThanOrEqual(meter.truePeak, -1 + 0.05, "true peaks under the ceiling")
    }

    func testTheLimiterDoesntPumpTheSteadyLevel() throws {
        let (input, transients) = burstsWithTransients()
        var limiter = try chain([Effect(type: "limiter", params: ["ceiling": .number(-1)])])
        let output = limiter.processAll(input)
        // Between the clicks, once the release has run, it's the input.
        for at in transients {
            let from = at + 0.5, to = at + 0.75
            XCTAssertEqual(rms(output, from: from, to: to), rms(input, from: from, to: to), accuracy: 0.1, "steady level after the click at \(at) s")
        }
        // And it never turns the steady tone down by more than the click
        // needed, for no longer than the release takes.
        XCTAssertEqual(rms(output, from: 0, to: 0.49), rms(input, from: 0, to: 0.49), accuracy: 0.05)
    }

    func testTheLimiterKeepsTheSoundInSync() throws {
        // Silence, then a burst starting on a known sample.
        var input = [Float](repeating: 0, count: 48_000 * 2)
        let onset = 12_345
        for i in onset..<(onset + 4_800) {
            let v = Float(1.5 * sin(2 * Double.pi * 440 * Double(i - onset) / Self.rate))
            input[2 * i] = v
            input[2 * i + 1] = v
        }
        var limiter = try chain([Effect(type: "limiter")])
        XCTAssertGreaterThan(limiter.latency, 0, "it looks ahead")
        let output = limiter.processAll(input)
        let first = (0..<48_000).first { abs(output[2 * $0]) > 1e-6 }
        XCTAssertEqual(first, onset + 1, "the first non-zero sample of the sine is the one after the onset")
        let last = (0..<48_000).last { abs(output[2 * $0]) > 1e-6 }
        XCTAssertEqual(try XCTUnwrap(last), onset + 4_799, accuracy: 1)
    }

    // MARK: - Compressor

    func testTheCompressorAppliesItsRatioOverTheThreshold() throws {
        // 12 dB over a -24 dBFS threshold at 3:1 comes out 4 dB over it.
        let input = tone(rmsDB: -12, seconds: 1)
        var compressor = try chain([Effect(type: "compressor", params: [
            "threshold": .number(-24), "ratio": .number(3), "knee": .number(0), "attack": .number(5), "release": .number(100)
        ])])
        let output = compressor.processAll(input)
        XCTAssertEqual(rms(output, from: 0.5, to: 1), -20, accuracy: 0.3)
    }

    func testTheCompressorLeavesQuietSoundAlone() throws {
        let input = tone(rmsDB: -36, seconds: 0.5)
        var compressor = try chain([Effect(type: "compressor", params: ["threshold": .number(-24), "ratio": .number(4)])])
        let output = compressor.processAll(input)
        XCTAssertEqual(rms(output, from: 0.1, to: 0.5), -36, accuracy: 0.05)
    }

    func testMakeupGainLiftsTheResult() throws {
        let input = tone(rmsDB: -36, seconds: 0.5)
        var compressor = try chain([Effect(type: "compressor", params: ["threshold": .number(-24), "makeup": .number(3)])])
        XCTAssertEqual(rms(compressor.processAll(input), from: 0.1, to: 0.5), -33, accuracy: 0.05)
    }

    func testTheEffectsRunAtTheLevelTheClipPlaysAt() throws {
        // A file at -36 dBFS lifted 24 dB plays at -12: 12 dB over the
        // threshold, so 3:1 takes 8 dB off. The file stays at file scale
        // (the gain lane lifts it), so it comes out at -44.
        let input = tone(rmsDB: -36, seconds: 1)
        var compressor = try chain([Effect(type: "compressor", params: [
            "threshold": .number(-24), "ratio": .number(3), "knee": .number(0)
        ])], levelDB: 24)
        XCTAssertEqual(rms(compressor.processAll(input), from: 0.5, to: 1), -44, accuracy: 0.3)
    }

    // MARK: - Voice clean-up

    func testCleanupTakesTheRumbleOutAndKeepsTheVoice() throws {
        var cleanup = try chain([Effect(type: "voiceCleanup", params: ["highPass": .number(100), "expanderThreshold": .number(-70)])])
        XCTAssertLessThan(rms(cleanup.processAll(tone(rmsDB: -20, frequency: 30, seconds: 1)), from: 0.5, to: 1), -20 - 15, "30 Hz rumble")
        XCTAssertEqual(rms(cleanup.processAll(tone(rmsDB: -20, frequency: 1_000, seconds: 1)), from: 0.5, to: 1), -20, accuracy: 0.1, "1 kHz")
    }

    func testCleanupTurnsDownWhatsUnderTheNoiseFloor() throws {
        // Room noise at -55 dBFS, then speech at -20.
        let noise = tone(rmsDB: -55, frequency: 2_000, seconds: 1)
        let speech = tone(rmsDB: -20, frequency: 300, seconds: 1)
        var cleanup = try chain([Effect(type: "voiceCleanup", params: [
            "highPass": .number(0), "expanderThreshold": .number(-45), "expanderRange": .number(12)
        ])])
        let output = cleanup.processAll(noise + speech)
        XCTAssertEqual(rms(output, from: 0.6, to: 1), -55 - 12, accuracy: 0.5, "the noise goes down by the range")
        XCTAssertEqual(rms(output, from: 1.3, to: 2), -20, accuracy: 0.1, "the speech is untouched")
    }

    // MARK: - The chain

    func testOnlyEnabledDynamicsEffectsMakeAChain() {
        XCTAssertNil(AudioEffectChain(effects: [Effect(type: "pitchShift")], registry: .standard, channels: 2, levelDB: 0))
        XCTAssertNil(AudioEffectChain(effects: [Effect(type: "limiter", enabled: false)], registry: .standard, channels: 2, levelDB: 0))
        var clip = Clip(content: .media(mediaID: "med_a"), start: .zero, duration: t(1))
        clip.audio = AudioProperties(effects: [Effect(type: "pitchShift"), Effect(type: "compressor"), Effect(type: "limiter", enabled: false)])
        XCTAssertEqual(AudioEffects.effects(of: clip, registry: .standard).map(\.type), ["compressor"])
    }

    func testTheCacheIdentityFollowsTheSettings() throws {
        let effects = [Effect(id: "fx_a", type: "compressor"), Effect(id: "fx_b", type: "limiter")]
        let a = AudioEffects.identity(effects, registry: .standard, levelDB: 23.5)
        // IDs don't matter, values and order do.
        XCTAssertEqual(a, AudioEffects.identity([Effect(id: "fx_c", type: "compressor"), Effect(id: "fx_d", type: "limiter")], registry: .standard, levelDB: 23.5))
        XCTAssertNotEqual(a, AudioEffects.identity(effects.reversed(), registry: .standard, levelDB: 23.5))
        XCTAssertNotEqual(a, AudioEffects.identity(effects, registry: .standard, levelDB: 20))
        var louder = effects
        louder[1].params["ceiling"] = .number(-2)
        XCTAssertNotEqual(a, AudioEffects.identity(louder, registry: .standard, levelDB: 23.5))
    }

    func testThePlanCarriesTheLevelTheEffectsRunAt() {
        let mic = MediaItem(id: "med_mic", path: "mic.wav", kind: .audio, role: .other, duration: t(60), hasAudio: true)
        let assets = FakeAssets()
        assets.loudnesses["med_mic"] = Loudness(integratedLUFS: -43.5, truePeakDBTP: -0.1, loudnessRange: 7)
        var clip = Clip(id: "clip_mic", content: .media(mediaID: "med_mic"), start: .zero, duration: t(10))
        clip.audio = AudioProperties(gainDB: 1, normalizeTo: -20, effects: [Effect(type: "limiter")])
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [clip])], media: [mic])
        let plan = RenderPlanner.plan(project, format: nil, assets: assets)
        XCTAssertEqual(try XCTUnwrap(plan.audioSegments.first).levelDB, 23.5 + 1, accuracy: 1e-9)
    }

    func testAJoinBetweenClipsWithDifferentEffectsIsntSeamless() {
        var a = Clip(id: "clip_a", content: .media(mediaID: "med_mic"), start: .zero, duration: t(2), sourceStart: .zero)
        var b = Clip(id: "clip_b", content: .media(mediaID: "med_mic"), start: t(2), duration: t(2), sourceStart: t(2))
        a.audio = AudioProperties(effects: [Effect(id: "fx_1", type: "limiter")])
        b.audio = AudioProperties(effects: [Effect(id: "fx_2", type: "limiter")])
        XCTAssertTrue(RenderPlanner.isSeamless(a, b), "the same limiter")
        b.audio?.effects[0].params["ceiling"] = .number(-3)
        XCTAssertFalse(RenderPlanner.isSeamless(a, b), "a different render each side")
    }

    /// A quiet take with a silent hole and clicks far over full scale once
    /// it's lifted 20 dB, exported with a limiter at -1: the peaks stay
    /// under, the hole stays where it was, and the steady tone keeps its
    /// level.
    func testAnExportHoldsTheCeilingAndKeepsSync() async throws {
        let media = try TestMedia()
        AudioEffects.cacheFolder = media.folder.appendingPathComponent("dynamics-cache", isDirectory: true)
        try await media.movie("quiet.mov", seconds: 3, draw: { TestMedia.fill($1, 0, 0, 0) }, sound: { i in
            let t = Double(i) / 48_000
            if (1.0..<1.2).contains(t) { return 0 }
            var v = pow(10, -40.0 / 20) * 2.0.squareRoot() * sin(2 * Double.pi * 220 * t)
            // Clicks at 0.5 and 2.0 s, 20 dB over the tone's peaks.
            for at in [0.5, 2.0] where (at..<(at + 0.005)).contains(t) {
                v += pow(10, (-37.0 + 20) / 20) * sin(2 * Double.pi * 1_500 * (t - at))
            }
            return Float(v)
        })
        let item = media.item("med_q", "quiet.mov", seconds: 3, audio: true)
        var clip = Clip(id: "clip_q", content: .media(mediaID: "med_q"), start: .zero, duration: t(3))
        clip.audio = AudioProperties(gainDB: 20, effects: [Effect(type: "limiter", params: ["ceiling": .number(-1)])])
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [clip])], media: [item])
        let out = media.folder.appendingPathComponent("limited.mp4")
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 2_000_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset, output: out).run()
        let samples = try await decodeAudio(out)
        XCTAssertEqual(Double(samples.count / 2) / Self.rate, 3, accuracy: 0.03)
        // AAC adds a few tenths of a dB to the peaks.
        XCTAssertLessThan(peakDB(samples), -1 + 0.5, "the clicks are held under the ceiling")
        XCTAssertEqual(rms(samples, from: 1.4, to: 1.9), -20, accuracy: 0.3, "the tone plays 20 dB up, as before")
        // The hole (1.0 to 1.2 s) hasn't moved.
        let after = (Int(1.05 * Self.rate)..<Int(1.4 * Self.rate)).first { abs(samples[$0 * 2]) > 0.02 }
        XCTAssertEqual(Double(try XCTUnwrap(after)) / Self.rate, 1.2, accuracy: 0.005)
        let before = (Int(0.8 * Self.rate)..<Int(1.15 * Self.rate)).last { abs(samples[$0 * 2]) > 0.02 }
        XCTAssertEqual(Double(try XCTUnwrap(before)) / Self.rate, 1.0, accuracy: 0.005)
    }

    /// The streaming render the cached file is made with: chunks in, the
    /// latency dropped, the tail flushed, the same length out.
    func testTheRenderStreamsInChunksAndStaysAligned() throws {
        let (input, _) = burstsWithTransients()
        var whole = try chain([Effect(type: "compressor"), Effect(type: "limiter")])
        let expected = whole.processAll(input)
        var streamed = try chain([Effect(type: "compressor"), Effect(type: "limiter")])
        var position = 0
        var output: [Float] = []
        try AudioEffects.render(chain: &streamed, channels: 2, read: { chunk in
            guard position < input.count else { return false }
            let end = min(input.count, position + 2 * 1_237)
            chunk = Array(input[position..<end])
            position = end
            return true
        }, write: { output += $0 })
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(output, expected)
    }
}
