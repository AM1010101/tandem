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
    /// Words this many dB under the others: (start, end, dB).
    var softWords: [(Double, Double, Double)] = []
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
        for (start, end, under) in words.map({ ($0.0, $0.1, 0.0) }) + softWords {
            let range = span((start, end))
            let gain = 0.08 * pow(10, -under / 20)
            for i in range {
                let t = Double(i) / Self.rate
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                out[i] += Float(buzz * gain) * fade(i, in: range)
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
    private func judge(
        _ take: Take, at time: Double, keeps side: CutAudit.Side, removed: ClosedRange<Double>? = nil, words: [ClosedRange<Double>] = []
    ) -> CutAudit.Edge {
        let energy = take.energy
        return CutAudit.judge(energy, levels: SpeechLevels(of: [energy]), at: time, keeps: side, removed: removed, words: words)
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

    func testACutBetweenTwoWordsWithNoPauseIsJudgedByHowQuietTheKeptSideIs() throws {
        // Fluent speech: 60 ms between the words, too short for a pause. A
        // cut in that dip keeps no voice beside it, so it's a clean join.
        let dip = Take(words: [(10.6, 11.3), (11.36, 11.8), (12.4, 12.8)])
        XCTAssertEqual(judge(dip, at: 11.33, keeps: .before).verdict, .clean, "the clip's last 25 ms is the dip")
        XCTAssertEqual(judge(dip, at: 11.33, keeps: .after).verdict, .clean)

        // The same words run together, as cutting a filler or a repeat out
        // of running speech leaves them: the kept word is still sounding at
        // the cut, however exactly it sits on the word boundary (#64).
        let fluent = Take(words: [(10.6, 11.3), (11.3, 11.8), (12.4, 12.8)])
        let edge = judge(fluent, at: 11.3, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertLessThan(try XCTUnwrap(edge.margin), CutAudit.clippedUnder)
        XCTAssertEqual(edge.fix, .nothingNearby, "no pause within reach either side")
    }

    func testCuttingTheLastOfAWordWhileItsSoundingClipsIt() throws {
        // Only 30 ms of the word either side, but the cut is through the
        // voice at full level, so it's heard as chopped.
        let take = Take(words: [(11.0, 11.6), (12.0, 12.5)])
        let end = judge(take, at: 11.57, keeps: .before)
        XCTAssertTrue(end.clipped, "30 ms of the word's tail cut off")
        XCTAssertEqual(try XCTUnwrap(end.suggestion), 11.64, accuracy: 0.015, "on past the tail into the pause")
        let start = judge(take, at: 11.57, keeps: .after)
        XCTAssertTrue(start.clipped, "a 30 ms fragment of the word left at the clip's start")
        XCTAssertEqual(try XCTUnwrap(start.suggestion), 11.64, accuracy: 0.015, "past the fragment")
    }

    func testACutInTheClosureBeforeAFinalTIsClipped() throws {
        // "extract": the vowel, the 50 ms closure before the "t", a 30 ms
        // burst, then a pause. The clip's last 25 ms is the quiet closure,
        // so its level says nothing; the short burst past the cut, with a
        // pause after it, is what gives it away: it belongs to the kept word.
        let take = Take(words: [(10.8, 11.3), (12.0, 12.4)], releases: [(11.35, 11.38)])
        let edge = judge(take, at: 11.33, keeps: .before)
        XCTAssertTrue(edge.clipped, "\"extract\" cut to \"extrac\"")
        XCTAssertGreaterThan(try XCTUnwrap(edge.margin), CutAudit.cleanFrom, "quiet beside the cut")
        let pause = try XCTUnwrap(edge.pause)
        XCTAssertEqual(pause.lowerBound, 11.38, accuracy: 0.015, "the pause after the burst")
        let to = try XCTUnwrap(edge.suggestion)
        XCTAssertGreaterThan(to, 11.38, "past the burst")
        XCTAssertEqual(to, 11.42, accuracy: 0.015)
        XCTAssertEqual(edge.fix, .trim(to: to))

        // The pause it moves into is in the cut material, but it's not a
        // word, so it may come back; the cut word after it may not.
        let cut = judge(take, at: 11.33, keeps: .before, removed: 11.33...12.6, words: [11.97...12.42])
        XCTAssertEqual(cut.fix, .trim(to: to))
    }

    func testTheKeptSidesLevelAgainstTheSpeechSaysHowCleanAJoinIs() throws {
        // A word, then its last 30 ms some dB under the speech, cut there,
        // with the next word (cut material) running straight on: no pause
        // within reach either side.
        func join(under: Double) -> CutAudit.Edge {
            let take = Take(length: 6, words: [(10.5, 11.47), (11.5, 12.2), (13, 14)], softWords: [(11.47, 11.5, under)])
            return judge(take, at: 11.5, keeps: .before)
        }
        let chopped = join(under: 3)
        XCTAssertEqual(chopped.verdict, .clipped, "within 3 dB of the speech, like each of Mike's cut-offs")
        XCTAssertEqual(try XCTUnwrap(chopped.margin), 3, accuracy: 2)
        XCTAssertEqual(chopped.fix, .nothingNearby)
        let marginal = join(under: 12)
        XCTAssertEqual(marginal.verdict, .marginal)
        XCTAssertFalse(marginal.clipped, "marginal doesn't fail")
        XCTAssertEqual(try XCTUnwrap(marginal.margin), 12, accuracy: 2)
        XCTAssertNil(marginal.fix)
        let clean = join(under: 18)
        XCTAssertEqual(clean.verdict, .clean, "a clean join is 15 dB or more under")
        XCTAssertFalse(clean.clipped)
    }

    func testAFixNeverPutsARemovedWordBack() throws {
        // "that [because] ...": the kept word runs straight into a cut one,
        // and the only pause in reach is after the cut word.
        let take = Take(length: 6, words: [(10.5, 11.5), (11.5, 11.75), (14.5, 15)])
        let because = 11.53...11.72
        let near = judge(take, at: 11.5, keeps: .before, removed: 11.5...12.4, words: [because])
        XCTAssertTrue(near.clipped)
        XCTAssertNil(near.suggestion, "trimming into that pause brings \"because\" back")
        XCTAssertEqual(near.fix, .putBack, "0.9 s cut here: put it back, filler and all")
        let far = judge(take, at: 11.5, keeps: .before, removed: 11.5...14.0, words: [because])
        XCTAssertTrue(far.clipped)
        XCTAssertNil(far.suggestion)
        XCTAssertEqual(far.fix, .nothingNearby, "2.5 s is too much to put back")
        // With no transcript to say a word's there, the audio can't tell.
        XCTAssertEqual(try XCTUnwrap(judge(take, at: 11.5, keeps: .before, removed: 11.5...12.4).suggestion), 11.79, accuracy: 0.015)
    }

    func testAnEdgeInARealPauseIsClean() {
        let take = Take(words: [(11.0, 11.5), (11.6, 12.0)])
        for side in [CutAudit.Side.before, .after] {
            let edge = judge(take, at: 11.55, keeps: side)
            XCTAssertEqual(edge.verdict, .clean)
            XCTAssertNil(edge.fix)
        }
    }

    func testSeventyMillisecondsOfQuietIsAPause() {
        // #64 measured real pauses at 70 ms or more under floor + 9 dB.
        let take = Take(words: [(11.0, 11.5), (11.575, 12.0)])
        XCTAssertEqual(judge(take, at: 11.54, keeps: .before).verdict, .clean)
        XCTAssertEqual(judge(take, at: 11.54, keeps: .after).verdict, .clean)
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
        // 0.08 s before the word: before a word, the end of the quiet is
        // often its "p" or "t" bursting, after a silent closure.
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 10.92, accuracy: 0.015, "inside the pause before the word")
    }

    func testNoPauseInReachLeavesItToAPerson() {
        let take = Take(words: [(10.5, 12.5)])
        let edge = judge(take, at: 11.5, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertNil(edge.suggestion)
        XCTAssertNil(edge.lost, "no pause within reach past the cut")
        XCTAssertEqual(edge.fix, .nothingNearby)
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
