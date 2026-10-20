import AVFoundation
import CoreVideo
import Foundation
import TandemCore

/// Reads every frame of stretches of the timeline, composed small, and
/// measures each for `tandem check` (`QualityCheck`): a grid of tiles over
/// the frame, each tile's colour and how evenly lit it is.
///
/// It reads the composition the way an export does (sequentially, through
/// AVFoundation's reader), at a few hundred pixels wide and from proxies
/// where they're ready, so a minute of 4K timeline scans in seconds.
public enum FrameScanner {
    /// Tiles across the frame; rows keep them about square (18 for 16:9).
    static let columns = 32
    /// Stretches are read in pieces this long, on the same grid as the
    /// check's cache (`QualityCheck.pieces`), several at once: one reader
    /// decodes and composes a frame at a time, which leaves the media engine
    /// and the GPU idle much of the time. A piece starts from the keyframe
    /// before it, a fraction of a second of proxy.
    public static let pieceLength = Time(seconds: 10)
    /// How many pieces are read at once.
    static var readers: Int { max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 3)) }

    /// Every frame of `ranges`, rendered `width` wide and measured. With
    /// `scanlines`, each frame's lines are measured too (in
    /// `QualityCheck.scanlineBands` bands), to tell a scroll from a new page.
    public static func scan(_ context: RenderContext, ranges: [TimeRange], width: Int = 384, scanlines: Bool = false) async throws -> [FrameStats] {
        var context = context
        let canvas = context.renderSize
        let height = Int((Double(width) * canvas.height / max(canvas.width, 1)).rounded())
        context.sizeOverride = CGSize(width: width, height: max(2, height))
        let (ready, _) = await ConvertedMedia.prepare(context)
        let built = try await CompositionAssembler.build(ready)
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { return [] }
        let timeline = TimeRange(start: .zero, end: built.duration)
        let wanted = ranges.compactMap { $0.intersection(timeline) }.filter { $0.duration > .zero }
        let pieces = QualityCheck.pieces(of: wanted, every: pieceLength)
        let source = Unchecked((built: built, tracks: tracks))
        return try await inParallel(pieces, limit: readers) { piece in
            try Task.checkCancellation()
            return try await read(source.value.built, tracks: source.value.tracks, range: piece, scanlines: scanlines)
        }
    }

    /// `body` over each of `pieces`, `limit` at a time, joined in order.
    static func inParallel<T: Sendable>(_ pieces: [TimeRange], limit: Int, _ body: @escaping @Sendable (TimeRange) async throws -> [T]) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
            var results = [[T]](repeating: [], count: pieces.count)
            var next = 0
            while next < min(max(1, limit), pieces.count) {
                let index = next
                group.addTask { (index, try await body(pieces[index])) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < pieces.count {
                    let more = next
                    group.addTask { (more, try await body(pieces[more])) }
                    next += 1
                }
            }
            return results.flatMap { $0 }
        }
    }

    /// Reads one stretch on a thread of its own: the reader blocks.
    private static func read(_ built: BuiltComposition, tracks: [AVAssetTrack], range: TimeRange, scanlines: Bool) async throws -> [FrameStats] {
        let source = Unchecked((built: built, tracks: tracks))
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try readNow(source.value.built, tracks: source.value.tracks, range: range, scanlines: scanlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func readNow(_ built: BuiltComposition, tracks: [AVAssetTrack], range: TimeRange, scanlines: Bool) throws -> [FrameStats] {
        let reader = try AVAssetReader(asset: built.composition)
        // As an export does: frames that can't be decoded from a seek are
        // read from their keyframe, and those before the range dropped.
        let from = ExportPipeline.readStart(range.start, instructions: built.videoComposition.instructions)
        reader.timeRange = CMTimeRange(start: from.cmTime, end: range.end.cmTime)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RenderError.export("couldn't start reading the timeline") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var stats: [FrameStats] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = Time(cmTime: CMSampleBufferGetPresentationTimeStamp(sample))
            guard time >= range.start, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            stats.append(measure(pixels, at: time, scanlines: scanlines))
        }
        if reader.status == .failed { throw reader.error ?? RenderError.export("reading the timeline failed") }
        return stats
    }

    /// A BGRA frame's tile grid, and its scanlines when asked for.
    static func measure(_ pixels: CVPixelBuffer, at time: Time, scanlines: Bool = false) -> FrameStats {
        let (grid, lines) = tiles(of: pixels, scanlines: scanlines)
        return FrameStats(time: time, tiles: grid, columns: columns, scanlines: lines)
    }

    /// The tile grid over a BGRA frame, and with `scanlines` the mean luma
    /// of each line in `QualityCheck.scanlineBands` bands across it, band by
    /// band.
    static func tiles(of pixels: CVPixelBuffer, scanlines: Bool = false) -> (tiles: [FrameStats.Tile], scanlines: [UInt8]) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixels) else { return ([], []) }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let columns = Self.columns
        let rows = max(1, Int((Double(columns) * Double(height) / Double(width)).rounded()))
        let bands = scanlines ? QualityCheck.scanlineBands : 0
        var red = [UInt32](repeating: 0, count: columns * rows)
        var green = red
        var blue = red
        var luma = red
        var lumaSquared = [UInt64](repeating: 0, count: columns * rows)
        var count = red
        var lines = [UInt32](repeating: 0, count: bands * height)
        var lineCounts = [UInt32](repeating: 0, count: bands * height)
        // Which tile column, and which band's lines, each x falls in.
        let tileColumn = (0..<width).map { $0 * columns / width }
        let bandStart = bands > 0 ? (0..<width).map { $0 * bands / width * height } : []
        for y in 0..<height {
            let row = bytes + y * rowBytes
            let tileRow = y * rows / height * columns
            for x in 0..<width {
                let pixel = row + x * 4
                let b = UInt32(pixel[0]), g = UInt32(pixel[1]), r = UInt32(pixel[2])
                // Rec. 709 weights in 256ths.
                let l = (54 * r + 183 * g + 19 * b) >> 8
                let tile = tileRow + tileColumn[x]
                red[tile] += r
                green[tile] += g
                blue[tile] += b
                luma[tile] += l
                lumaSquared[tile] += UInt64(l * l)
                count[tile] += 1
                if bands > 0 {
                    let line = bandStart[x] + y
                    lines[line] += l
                    lineCounts[line] += 1
                }
            }
        }
        let grid = (0..<(columns * rows)).map { tile in
            let n = Double(max(count[tile], 1))
            let mean = Double(luma[tile]) / n
            let variance = max(0, Double(lumaSquared[tile]) / n - mean * mean)
            return FrameStats.Tile(
                red: Double(red[tile]) / n / 255, green: Double(green[tile]) / n / 255, blue: Double(blue[tile]) / n / 255,
                spread: variance.squareRoot() / 255
            )
        }
        let profile = lines.indices.map { UInt8(clamping: lines[$0] / max(lineCounts[$0], 1)) }
        return (grid, profile)
    }
}
