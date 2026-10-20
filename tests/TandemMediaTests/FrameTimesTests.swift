import XCTest
@testable import TandemCore
@testable import TandemMedia

/// A file's frame times, read from its sample table for `tandem check`'s
/// low frame rate note, and cached per file.
final class FrameTimesTests: TempFolderTestCase {
    func testReadsAScreenRecordingsUnevenFramesAndCachesThem() async throws {
        // 30 fps, then 5 a second, as a screen recording slows down while
        // nothing much changes.
        let times = (0..<30).map { Double($0) / 30 } + (0..<10).map { 1 + Double($0) / 5 }
        let url = file("source/demo-screen.mov")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await SyntheticMedia.writeMovie(to: url, .init(frameTimes: times, audio: nil))
        let folder = ProjectFolder(root: temp)
        var item = MediaItem(id: "med_s", path: "source/demo-screen.mov", kind: .video, role: .screen, hasVideo: true)
        // Scanned media always has one, and it keys the cache without the file.
        item.fingerprint = "demo-fingerprint"

        let first = await FrameTimes.read(item, in: folder)
        let read = try XCTUnwrap(first)
        XCTAssertEqual(read.count, times.count)
        for (got, wanted) in zip(read, times) { XCTAssertEqual(got.seconds, wanted, accuracy: 0.002) }

        let cached = try FileManager.default.contentsOfDirectory(atPath: folder.cacheFolder.appendingPathComponent("frametimes").path)
        XCTAssertEqual(cached.count, 1, "cached per file")
        // Read back from the cache, not the file.
        try FileManager.default.removeItem(at: url)
        let gone = await FrameTimes.read(url)
        XCTAssertNil(gone)
        let again = await FrameTimes.read(item, in: folder)
        XCTAssertEqual(again, read)
    }
}
