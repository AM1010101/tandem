import AVFoundation
import CryptoKit
import Foundation
import TandemCore

/// A clip's dynamics effects (compressor, limiter, voice clean-up) in
/// order, run at the level the clip plays at.
///
/// Thresholds and ceilings mean dBFS as the timeline plays the clip, after
/// its levelling and gain, so the samples are lifted by `levelDB` first and
/// put back after: the gain lane still does the lifting, and a limiter at
/// -1 holds a quiet mic lifted 24 dB under -1 dBFS on the timeline. Fades
/// and gain keyframes come after the effects, as on a mixing desk.
///
/// The limiter looks ahead, so the output is `latency` frames late:
/// `processAll` and `AudioEffects.render` drop that many frames from the
/// start and flush the tail, so the result lines up with the input sample
/// for sample.
struct AudioEffectChain {
    enum Stage {
        case compressor(Compressor)
        case limiter(TruePeakLimiter)
        case highPass(HighPass)
        case expander(Expander)
    }

    let channels: Int
    private(set) var stages: [Stage] = []
    private let gain: Double

    /// Nil when none of `effects` is an enabled dynamics effect.
    init?(effects: [Effect], registry: EffectRegistry, channels: Int, levelDB: Double, sampleRate: Double = Double(AudioBuffers.sampleRate)) {
        self.channels = channels
        gain = pow(10, levelDB / 20)
        for effect in effects where effect.enabled && EffectRegistry.dynamicsTypes.contains(effect.type) {
            let params = registry.definition(effect.type)?.resolvedParams(effect) ?? effect.params
            func number(_ key: String, _ fallback: Double) -> Double { params[key]?.number ?? fallback }
            switch effect.type {
            case "compressor":
                stages.append(.compressor(Compressor(
                    channels: channels, sampleRate: sampleRate,
                    thresholdDB: number("threshold", -14), ratio: number("ratio", 3),
                    attackSeconds: number("attack", 10) / 1000, releaseSeconds: number("release", 200) / 1000,
                    kneeDB: number("knee", 6), makeupDB: number("makeup", 0)
                )))
            case "limiter":
                stages.append(.limiter(TruePeakLimiter(
                    channels: channels, sampleRate: sampleRate, ceilingDBTP: min(number("ceiling", -1), 0),
                    releaseSeconds: max(number("release", 100), 1) / 1000
                )))
            case "voiceCleanup":
                let frequency = number("highPass", 80)
                if frequency > 0 { stages.append(.highPass(HighPass(channels: channels, sampleRate: sampleRate, frequency: frequency))) }
                let range = number("expanderRange", 10)
                if range > 0 {
                    stages.append(.expander(Expander(channels: channels, sampleRate: sampleRate, thresholdDB: number("expanderThreshold", -40), rangeDB: range)))
                }
            default:
                break
            }
        }
        if stages.isEmpty { return nil }
    }

    /// Frames between an input and its output: the limiters' lookahead.
    var latency: Int {
        stages.reduce(0) { total, stage in
            if case .limiter(let limiter) = stage { return total + limiter.latency }
            return total
        }
    }

    /// Processes interleaved samples in place. The result is `latency`
    /// frames late.
    mutating func process(_ samples: inout [Float]) {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        let lift = Float(gain), back = Float(1 / gain)
        samples.withUnsafeMutableBufferPointer { buffer in
            if lift != 1 { for i in buffer.indices { buffer[i] *= lift } }
            for index in stages.indices {
                switch stages[index] {
                case .compressor(var stage):
                    stage.process(buffer, frames: frames)
                    stages[index] = .compressor(stage)
                case .limiter(var stage):
                    stage.process(buffer, frames: frames)
                    stages[index] = .limiter(stage)
                case .highPass(var stage):
                    stage.process(buffer, frames: frames)
                    stages[index] = .highPass(stage)
                case .expander(var stage):
                    stage.process(buffer, frames: frames)
                    stages[index] = .expander(stage)
                }
            }
            if back != 1 { for i in buffer.indices { buffer[i] *= back } }
        }
    }

    /// The last `latency` frames, pushed out with silence.
    mutating func flush() -> [Float] {
        var tail = [Float](repeating: 0, count: latency * channels)
        process(&tail)
        return tail
    }

    /// The whole of `input` processed, lined up with it and as long.
    mutating func processAll(_ input: [Float]) -> [Float] {
        var output = input
        process(&output)
        output += flush()
        return Array(output.dropFirst(latency * channels))
    }
}

/// Renders clips' dynamics effects ahead of time. The whole source file is
/// run through the clip's chain once, into a cached lossless file the
/// composition then plays instead of the original, so playback, review
/// clips, `tandem loudness` and export all hear the same thing. Like
/// `PitchShift`, but per file rather than per segment: the effects don't
/// animate, so every clip of a take with the same effects and level shares
/// one render, cuts and trims don't render again, and the compressor's
/// state runs on across a cut the way it would in the source.
///
/// A clip with voice isolation plays the isolated voice file, which gets
/// its own render. Partly isolated, both files are rendered at the clip's
/// level, each as if it played alone; they're mostly the same voice, so
/// their gains move together.
enum AudioEffects {
    static let version = 1
    static let sampleRate = Double(AudioBuffers.sampleRate)
    /// Frames per chunk read and processed.
    static let chunk = 8192
    /// Where rendered copies are kept (tests point it elsewhere).
    nonisolated(unsafe) static var cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tandem/dynamics", isDirectory: true)

    /// The clip's enabled dynamics effects, in order.
    static func effects(of clip: Clip, registry: EffectRegistry) -> [Effect] {
        (clip.audio?.effects ?? []).filter { $0.enabled && EffectRegistry.dynamicsTypes.contains($0.type) }
    }

    /// What the render depends on besides the source: each effect's type
    /// and resolved values in order, and the level it runs at.
    static func identity(_ effects: [Effect], registry: EffectRegistry, levelDB: Double) -> String {
        var parts = [String(format: "level %.3f", levelDB)]
        for effect in effects where effect.enabled && EffectRegistry.dynamicsTypes.contains(effect.type) {
            let params = registry.definition(effect.type)?.resolvedParams(effect) ?? effect.params
            let values = params.keys.sorted().map { key in "\(key)=\(params[key]?.number.map { String(format: "%.4f", $0) } ?? "\(String(describing: params[key]))")" }
            parts.append("\(effect.type)(\(values.joined(separator: ",")))")
        }
        return parts.joined(separator: "|")
    }

    /// The cached processed sound of `url`, rendering it if needed. It
    /// starts where the file's sound starts and is as long.
    static func file(source url: URL, levelDB: Double, effects: [Effect], registry: EffectRegistry) async throws -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        var key = "v\(version)|\(url.path)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes?[.size] as? Int ?? 0)"
        key += "|" + identity(effects, registry: registry, levelDB: levelDB)
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheFolder
        let cached = folder.appendingPathComponent("\(hash.prefix(32)).caf")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard var chain = AudioEffectChain(effects: effects, registry: registry, channels: AudioBuffers.channels, levelDB: levelDB) else { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("\(UUID().uuidString).caf")
        do {
            try await render(url, chain: &chain, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        // Another build (the viewer's, say) may have finished it first.
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.removeItem(at: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: cached)
        }
        return cached
    }

    /// Decodes the file's sound as 48 kHz stereo, runs it through `chain`
    /// and writes it as 24-bit Apple Lossless.
    static func render(_ url: URL, chain: inout AudioEffectChain, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw RenderError.media("No sound in \(url.lastPathComponent) to process.")
        }
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: AudioBuffers.readerSettings)
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? RenderError.media("Couldn't read \(url.lastPathComponent).") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let channels = AudioBuffers.channels
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        // Lossless, at 24 bits so a quiet mic keeps its detail. The samples
        // are at the file's own scale (the chain puts its lift back), so
        // they stay under full scale unless makeup gain pushes them over.
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 24
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try render(chain: &chain, channels: channels, read: { chunk in
            guard let buffer = trackOutput.copyNextSampleBuffer() else {
                if reader.status == .failed { throw reader.error ?? RenderError.media("Couldn't read \(url.lastPathComponent).") }
                return false
            }
            chunk = AudioBuffers.samples(in: buffer)
            return true
        }, write: { samples in
            try write(samples, channels: channels, format: format, to: file)
        })
    }

    /// The streaming core: reads interleaved chunks until `read` returns
    /// false, processes them, drops the chain's latency from the front,
    /// flushes it at the end and writes exactly as many frames as came in.
    static func render(chain: inout AudioEffectChain, channels: Int, read: (inout [Float]) throws -> Bool, write: ([Float]) throws -> Void) throws {
        var toDrop = chain.latency * channels
        var chunk: [Float] = []
        func emit(_ samples: [Float]) throws {
            var samples = samples
            if toDrop > 0 {
                let dropped = min(toDrop, samples.count)
                samples.removeFirst(dropped)
                toDrop -= dropped
            }
            if !samples.isEmpty { try write(samples) }
        }
        while try read(&chunk) {
            guard !chunk.isEmpty else { continue }
            try Task.checkCancellation()
            chain.process(&chunk)
            try emit(chunk)
        }
        try emit(chain.flush())
    }

    private static func write(_ samples: [Float], channels: Int, format: AVAudioFormat, to file: AVAudioFile) throws {
        let frames = samples.count / channels
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            let destination = buffer.floatChannelData![c]
            for i in 0..<frames { destination[i] = samples[i * channels + c] }
        }
        try file.write(from: buffer)
    }
}
