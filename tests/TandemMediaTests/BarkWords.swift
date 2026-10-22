import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// Transcripts for the cut tests on the Ian whiteboard video's mics: one
/// JSON per file, `{"words": [{"start", "end", "text"}]}` in the engine's
/// own times (tandem-testdata/ian-whiteboard/bark has Bark 3.0 Pro's).
enum BarkWords {
    struct File: Decodable {
        struct Word: Decodable {
            var start: Double
            var end: Double
            var text: String
        }
        var words: [Word]
    }

    /// The words in `json`, aligned to `audio`'s sound as Tandem does when
    /// it reads a transcript (`TranscriptAlignment`), or in the engine's own
    /// times with no `audio`.
    static func load(_ json: URL, aligningTo audio: URL? = nil) throws -> [CutAudit.Word] {
        let words = try JSONDecoder().decode(File.self, from: Data(contentsOf: json)).words
        guard let audio else { return words.map { CutAudit.Word(text: $0.text, start: $0.start, end: $0.end) } }
        let raw = words.map { TranscriptWord(text: $0.text, start: Time(seconds: $0.start), end: Time(seconds: $0.end)) }
        return TranscriptAlignment.align(raw, waveform: try waveform(audio)).map {
            CutAudit.Word(text: $0.text, start: $0.start.seconds, end: $0.end.seconds)
        }
    }

    /// The file's waveform as Tandem caches it: the loudest sample in each
    /// 10 ms, over every channel.
    static func waveform(_ url: URL) throws -> Waveform {
        let file = try AVAudioFile(forReading: url)
        let channels = Int(file.processingFormat.channelCount)
        let perPeak = Int(file.processingFormat.sampleRate / 100)
        let chunk = AVAudioFrameCount(perPeak * 1000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
        var peaks: [Float] = []
        var peak: Float = 0, filled = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                for c in 0..<channels { peak = max(peak, abs(data[c][i])) }
                filled += 1
                if filled == perPeak {
                    peaks.append(peak)
                    peak = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { peaks.append(peak) }
        return Waveform(samplesPerSecond: 100, peaks: peaks)
    }
}
