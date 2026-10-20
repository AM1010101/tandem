import AVFoundation
@testable import TandemMedia
import XCTest

/// Lining a second camera or an external mic up with the camera take by
/// their sound (`SoundSync`), on made-up rooms: bursts of noise like
/// syllables, heard by two recorders that started at different times, one
/// running a touch fast, each with its own hiss.
final class SoundSyncTests: TempFolderTestCase {
    func testAFileThatStartedFirstAndStopsPartWayThrough() async throws {
        // The reference starts 3 s into the room and runs 120 s; the file
        // started 0.145 s in and runs 60 s. So a moment is 2.855 s further
        // into the file than into the reference.
        let room = Room(seconds: 125, seed: 1)
        let reference = try room.record(to: file("camera.wav"), from: 3, seconds: 120, seed: 2)
        let other = try room.record(to: file("mic.wav"), from: 0.145, seconds: 60, gain: 0.5, seed: 3)
        let match = try await SoundSync.match(reference: reference, file: other)
        XCTAssertEqual(match.offset, 2.855, accuracy: 0.0002)
        XCTAssertEqual(try XCTUnwrap(match.drift), 0, accuracy: 0.0003)
        XCTAssertEqual(match.overlapStart, 0, accuracy: 0.01)
        XCTAssertEqual(match.overlapEnd, 57.145, accuracy: 0.01)
        XCTAssertGreaterThan(match.confidence, SoundSync.minimumConfidence)
    }

    func testAFileThatStartsLaterAndDrifts() async throws {
        // The file starts 30.25 s into the reference and its clock runs
        // 20 ppm slow, so by its end (50 s) it's 1 ms behind.
        let room = Room(seconds: 125, seed: 4)
        let reference = try room.record(to: file("camera.wav"), from: 0, seconds: 120, seed: 5)
        let other = try room.record(to: file("angle.wav"), from: 30.25, seconds: 50, rate: 1.00002, seed: 6)
        let match = try await SoundSync.match(reference: reference, file: other)
        XCTAssertEqual(match.offset, -30.2505, accuracy: 0.0002, "the middle of the overlap")
        XCTAssertEqual(try XCTUnwrap(match.drift), -0.001, accuracy: 0.0003)
        XCTAssertEqual(match.overlapStart, 30.25, accuracy: 0.01)
        XCTAssertEqual(match.overlapEnd, 80.25, accuracy: 0.01)
    }

    func testFilesThatDontShareASoundAreRefused() async throws {
        let reference = try Room(seconds: 60, seed: 7).record(to: file("camera.wav"), from: 0, seconds: 60, seed: 8)
        let other = try Room(seconds: 60, seed: 9).record(to: file("other.wav"), from: 0, seconds: 40, seed: 10)
        do {
            let match = try await SoundSync.match(reference: reference, file: other)
            XCTFail("matched \(match)")
        } catch let error as SoundSync.NoMatch {
            XCTAssertTrue(error.localizedDescription.contains("same moment"), error.localizedDescription)
        }
    }
}

/// A room's sound at 48 kHz: syllable-length bursts of low-passed noise at
/// varied levels with short gaps.
private struct Room {
    static let rate = 48_000.0
    var samples: [Float]

    init(seconds: Double, seed: UInt64) {
        var rng = SeededRandom(seed)
        samples = [Float](repeating: 0, count: Int(seconds * Self.rate))
        var i = 0
        var smooth: Float = 0
        while i < samples.count {
            let burst = Int(rng.uniform(0.06, 0.35) * Self.rate)
            let gap = Int(rng.uniform(0.04, 0.5) * Self.rate)
            let level = Float(rng.uniform(0.05, 0.4))
            for j in 0..<burst where i + j < samples.count {
                let envelope = Float(sin(Double.pi * Double(j) / Double(burst)))
                smooth = 0.6 * smooth + 0.4 * Float(rng.uniform(-1, 1))
                samples[i + j] = level * envelope * smooth
            }
            i += burst + gap
        }
    }

    /// What a recorder heard from `from` s into the room for `seconds`, its
    /// clock running at `rate` times the room's, as a mono WAV.
    func record(to url: URL, from: Double, seconds: Double, rate: Double = 1, gain: Float = 1, seed: UInt64) throws -> URL {
        var rng = SeededRandom(seed)
        let count = Int(seconds * Self.rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        for n in 0..<count {
            let position = (from + Double(n) / Self.rate * rate) * Self.rate
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let a = index < samples.count ? samples[index] : 0
            let b = index + 1 < samples.count ? samples[index + 1] : 0
            data[n] = gain * (a + (b - a) * fraction) + 0.004 * Float(rng.uniform(-1, 1))
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }
}

private struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }
}
