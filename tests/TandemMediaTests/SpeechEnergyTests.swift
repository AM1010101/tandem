import AVFoundation
import XCTest
@testable import TandemMedia

/// A few seconds of a made-up take at 32 kHz: a low hum of room noise, a
/// faint hiss over it, and "words" (a buzz of harmonics up to 3 kHz) and
/// "s" sounds (hiss above 4 kHz that hardly registers in the full band)
/// and "k" releases (a loud burst of the same hiss) where asked. Times are
/// media seconds from `start`.
private struct Take {
    static let rate = 32_000.0
    var start = 10.0
    var length = 4.0
    var words: [(Double, Double)] = []
    var esses: [(Double, Double)] = []
    var releases: [(Double, Double)] = []

    var samples: [Float] {
        let count = Int(length * Self.rate)
        var out = [Float](repeating: 0, count: count)
        var seed: UInt32 = 12_345
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        // Room: noise smoothed to a low rumble, about -55 dB, with white
        // hiss about -85 dB on top.
        var rumble: Float = 0
        for i in 0..<count {
            rumble += (noise() - rumble) * 0.02
            out[i] = rumble * 0.03 + noise() * 0.00009
        }
        func span(_ range: (Double, Double)) -> Range<Int> {
            let from = max(0, Int(((range.0 - start) * Self.rate).rounded()))
            let to = min(count, Int(((range.1 - start) * Self.rate).rounded()))
            return from..<max(from, to)
        }
        // Voices fade in and out over a few milliseconds; a hard edge
        // would click, and the click is heard above 4 kHz.
        func fade(_ i: Int, in range: Range<Int>) -> Float {
            let ramp = 0.005 * Self.rate
            return Float(min(1, Double(i - range.lowerBound) / ramp, Double(range.upperBound - i) / ramp))
        }
        for word in words {
            let range = span(word)
            for i in range {
                let t = Double(i) / Self.rate
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                out[i] += Float(buzz * 0.08) * fade(i, in: range)
            }
        }
        // Each sample against the last: white noise tipped up to the top of
        // the band, about -54 dB over all for an "s", -34 for a release.
        for (hiss, gain) in esses.map({ ($0, Float(0.0025)) }) + releases.map({ ($0, Float(0.025)) }) {
            var last: Float = 0
            let range = span(hiss)
            for i in range {
                let white = noise()
                out[i] += (white - last) * gain * fade(i, in: range)
                last = white
            }
        }
        return out
    }

    var energy: SpeechEnergy { SpeechEnergy(samples: samples, sampleRate: Self.rate, start: start) }
}

final class SpeechEnergyTests: XCTestCase {
    private func judge(_ take: Take, at time: Double, keeps side: CutAudit.Side) -> CutAudit.Edge {
        let energy = take.energy
        return CutAudit.judge(energy, levels: SpeechLevels(of: [energy]), at: time, keeps: side)
    }

    func testFramesAreTenMillisecondsInMediaTime() {
        let energy = Take(words: [(11.0, 11.5)]).energy
        XCTAssertEqual(energy.full.count, 400)
        XCTAssertEqual(energy.high.count, 400)
        let levels = SpeechLevels(of: [energy])
        XCTAssertLessThan(energy.full[energy.index(of: 10.9)], levels.full, "the room before the word")
        XCTAssertGreaterThan(energy.full[energy.index(of: 11.2)], levels.full, "the word")
        XCTAssertLessThan(energy.full[energy.index(of: 11.6)], levels.full, "the room after it")
    }

    func testAWordRunningPastTheEndOfAClipIsClipped() throws {
        let take = Take(words: [(11.0, 11.6)])
        let edge = judge(take, at: 11.45, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertEqual(try XCTUnwrap(edge.lost), 0.15, accuracy: 0.015, "the rest of the word, cut off")
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.64, accuracy: 0.015, "just into the pause after the word")
        let pause = try XCTUnwrap(edge.pause)
        XCTAssertEqual(pause.lowerBound, 11.6, accuracy: 0.015)
        XCTAssertFalse(edge.highBandOnly)
        XCTAssertNil(edge.gap)
    }

    func testAWordThatEndsInSilenceBeforeTheCutIsFine() {
        let take = Take(words: [(11.0, 11.6)])
        XCTAssertFalse(judge(take, at: 11.75, keeps: .before).clipped)
        // The next word starting right after the cut is cut material, not a clip.
        XCTAssertFalse(judge(take, at: 11.0, keeps: .before).clipped, "the clip ends in the pause, just before a word it doesn't keep")
        XCTAssertFalse(judge(take, at: 11.6, keeps: .before).clipped, "the word ends on the cut")
    }

    func testAShortGapInsideAWordIsNotAPause() throws {
        // "ta" and "kes" with the 40 ms closure before the "k" between them,
        // and the "k" released at the start of "kes".
        let take = Take(words: [(11.0, 11.3), (11.34, 11.6)], releases: [(11.34, 11.37)])
        let edge = judge(take, at: 11.32, keeps: .before)
        XCTAssertTrue(edge.clipped, "a cut in the closure cuts \"takes\" to \"ta\"")
        XCTAssertEqual(try XCTUnwrap(edge.gap), 0.04, accuracy: 0.015)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.64, accuracy: 0.015, "the pause after the word is nearer than the one before it")
    }

    func testACutBetweenTwoWordsWithNoPauseIsFine() {
        // Fluent speech: 40 ms between the words, too short for a pause, and
        // the next word starts on a vowel, not a release.
        let take = Take(words: [(11.0, 11.3), (11.34, 11.6), (12.0, 12.4)])
        XCTAssertFalse(judge(take, at: 11.32, keeps: .before).clipped, "the cut is in the dip between the words")
        XCTAssertFalse(judge(take, at: 11.32, keeps: .after).clipped)
    }

    func testALittleVoiceEitherSideIsntAClippedWord() {
        let take = Take(words: [(11.0, 11.6), (12.0, 12.5)])
        XCTAssertFalse(judge(take, at: 11.57, keeps: .before).clipped, "30 ms of the word's tail cut off")
        XCTAssertFalse(judge(take, at: 11.57, keeps: .after).clipped, "a 30 ms fragment of the word left at the clip's start")
    }

    func testAFinalSIsHeardAboveFourKilohertz() throws {
        let take = Take(words: [(11.0, 11.4)], esses: [(11.4, 11.5)])
        let energy = take.energy
        let levels = SpeechLevels(of: [energy])
        XCTAssertLessThan(energy.full[energy.index(of: 11.45)], levels.full, "the s hardly registers in the full band")
        XCTAssertGreaterThan(energy.high[energy.index(of: 11.45)], levels.high)
        let edge = judge(take, at: 11.42, keeps: .before)
        XCTAssertTrue(edge.clipped, "the s is cut off")
        XCTAssertTrue(edge.highBandOnly)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.54, accuracy: 0.015)
    }

    func testAFragmentAtTheStartOfAClipIsDroppedWhenThatsNearer() throws {
        // The clip starts 80 ms before the end of a word that was cut out.
        let take = Take(words: [(11.0, 11.6), (12.0, 12.5)])
        let edge = judge(take, at: 11.52, keeps: .after)
        XCTAssertTrue(edge.clipped)
        XCTAssertEqual(edge.kept, 0.08, accuracy: 0.015)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.64, accuracy: 0.015, "later, past the fragment")
    }

    func testTheStartOfAWordCutOffAtTheStartOfAClipMovesEarlier() throws {
        let take = Take(words: [(11.0, 11.6)])
        let edge = judge(take, at: 11.1, keeps: .after)
        XCTAssertTrue(edge.clipped)
        XCTAssertEqual(try XCTUnwrap(edge.lost), 0.1, accuracy: 0.015)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 10.96, accuracy: 0.015, "just inside the pause before the word")
    }

    func testNoPauseInReachLeavesItToAPerson() {
        let take = Take(words: [(10.5, 12.5)])
        let edge = judge(take, at: 11.5, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertNil(edge.suggestion)
        XCTAssertNil(edge.lost, "no pause within reach past the cut")
    }

    func testATakeWithNoVoiceIsntJudged() {
        let silent = SpeechEnergy(samples: [Float](repeating: 0, count: 32_000), sampleRate: Take.rate, start: 0)
        XCTAssertFalse(SpeechLevels(of: [silent]).isVoice, "a screen recording's silent system sound")
        XCTAssertTrue(SpeechLevels(of: [Take(words: [(11.0, 11.6)]).energy]).isVoice)
    }

    func testReadsAFileInItsOwnTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speech-energy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("voice.wav")
        // Quiet to 3 s, a tone to 4 s, quiet to 6 s.
        try SyntheticMedia.writeAudioFile(to: url, segments: [(3, 0.0005), (1, 0.3), (2, 0.0005)], frequency: 300, sampleRate: 48_000, channels: 2)
        let energy = try await SpeechEnergy.read(url: url, from: 2, to: 5)
        XCTAssertEqual(energy.start, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(energy.full.count - 300), 1, "\(energy.full.count) frames")
        let levels = SpeechLevels(of: [energy])
        XCTAssertLessThan(energy.full[energy.index(of: 2.98)], levels.full)
        XCTAssertGreaterThan(energy.full[energy.index(of: 3.02)], levels.full)
        XCTAssertGreaterThan(energy.full[energy.index(of: 3.98)], levels.full)
        XCTAssertLessThan(energy.full[energy.index(of: 4.02)], levels.full)
    }
}
