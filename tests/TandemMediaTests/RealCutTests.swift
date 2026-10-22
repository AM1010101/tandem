import AVFoundation
import XCTest
@testable import TandemMedia

/// `CutAudit` on Ian's raw mic from the Ian whiteboard video (October 2026),
/// where Mike kept hearing words clipped after the take was tightened
/// (#64). Opt-in: set TANDEM_IAN_MIC to the path of
/// "Ian mic - B047_C002_0101QF.wav" (in tandem-testdata/ian-whiteboard/source).
final class RealCutTests: XCTestCase {
    private func mic() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TANDEM_IAN_MIC"], !path.isEmpty else {
            throw XCTSkip("set TANDEM_IAN_MIC to Ian's mic WAV to run")
        }
        return URL(fileURLWithPath: path)
    }

    /// Frames of the file from `from` to `to`. AVAudioFile seeks straight to
    /// them, so only these few seconds of the 18 minute WAV are read.
    private func energy(_ url: URL, from: Double, to: Double) throws -> SpeechEnergy {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition((from * rate).rounded())
        let count = AVAudioFrameCount(((to - from) * rate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        return SpeechEnergy(samples: samples, sampleRate: rate, start: from)
    }

    /// "So you're like, oh, I've [pause] processed everything": SpeechAnalyzer
    /// has "processed" at 647.82, but it starts at 647.60, so a clip
    /// starting on its transcript time cuts off "pro".
    func testAClipStartingOnProcessedsTranscriptTimeIsClipped() throws {
        // The speech level's 3 s either side, and room to reach a pause.
        let energy = try energy(try mic(), from: 644.5, to: 651.2)
        let levels = SpeechLevels(of: [energy])
        let removed = 646.74...647.82
        let edge = CutAudit.judge(energy, levels: levels, at: 647.82, keeps: .after, removed: removed)
        let report = "\(edge)"
        XCTAssertTrue(edge.clipped, report)
        let to = try XCTUnwrap(edge.suggestion, report)
        XCTAssertLessThanOrEqual(to, 647.60, "into the pause before \"processed\": \(report)")
        XCTAssertGreaterThan(to, 647.50, "not back into \"I've\": \(report)")
        XCTAssertEqual(edge.fix, .trim(to: to))
        print("Ian at 647.82: margin \(edge.margin.map { String(format: "%.1f", $0) } ?? "-") dB, lost \(edge.lost.map { String(format: "%.2f", $0) } ?? "-") s, pause \(edge.pause.map { "\($0)" } ?? "-"), moved to \(String(format: "%.3f", to))")

        // SpeechAnalyzer's words there. It has "I've" at 647.64-647.82,
        // right where "pro" is, so going by it the trim would bring a cut
        // word back. The audio can't tell it otherwise, so the check mustn't
        // trim either way: not back over "I've", and not on into
        // "processed" (the pause inside it at 647.88), but put the 1.08 s
        // back.
        let words = [
            646.8...646.92, 646.92...647.22, 647.22...647.4, 647.4...647.64, 647.64...647.82,
            647.82...648.06, 648.06...648.18, 648.18...648.36
        ]
        let withWords = CutAudit.judge(energy, levels: levels, at: 647.82, keeps: .after, removed: removed, words: words)
        XCTAssertTrue(withWords.clipped, "\(withWords)")
        XCTAssertNil(withWords.suggestion, "\(withWords)")
        XCTAssertEqual(withWords.fix, .putBack, "\(withWords)")
    }
}
