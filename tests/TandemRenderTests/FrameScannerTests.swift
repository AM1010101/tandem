import AVFoundation
import XCTest
import TandemCore
@testable import TandemRender

/// The scanner reads every frame of the composed timeline, and what it
/// measures is enough for `QualityCheck` to find planted problems.
final class FrameScannerTests: XCTestCase {
    func testReadsEveryFrameAndFindsAFlashAndAGreenScreen() async throws {
        let media = try TestMedia()
        // Grey, one white frame at 15, then a green screen box for frames
        // 40 to 49 over the grey.
        try await media.movie("planted.mov", seconds: 2, draw: { frame, c in
            TestMedia.fill(c, 0.4, 0.4, 0.4)
            if frame == 15 { TestMedia.fill(c, 1, 1, 1) }
            if (40..<50).contains(frame) {
                c.setFillColor(CGColor(srgbRed: 0.05, green: 0.85, blue: 0.1, alpha: 1))
                c.fill(CGRect(x: 40, y: 30, width: 120, height: 80))
            }
        })
        let clip = Clip(id: "clip_p", content: .media(mediaID: "med_p"), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_p", "planted.mov", seconds: 2)])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let frames = try await FrameScanner.scan(context, ranges: [TimeRange(start: .zero, end: t(2))], width: 192)
        XCTAssertEqual(frames.count, 60, "every frame at 30 fps")
        XCTAssertEqual(frames.first?.thumbnail.count, 32 * 18)

        let problems = QualityCheck.frameProblems(frames, in: project)
        XCTAssertEqual(problems.map(\.kind), [.whiteBlock, .unkeyed], "\(problems.map(\.message))")
        let flash = try XCTUnwrap(problems.first)
        XCTAssertEqual(flash.start.seconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(flash.frames, 1)
        let green = try XCTUnwrap(problems.last)
        XCTAssertEqual(green.start.seconds, 40.0 / 30, accuracy: 0.001)
        XCTAssertEqual(green.frames, 10)
        XCTAssertEqual(green.clipIDs, ["clip_p"])
    }

    func testOnlyTheRangesAskedForAreRead() async throws {
        let media = try TestMedia()
        try await media.movie("grey.mov", seconds: 3, draw: { _, c in TestMedia.fill(c, 0.5, 0.5, 0.5) })
        let clip = Clip(id: "clip_g", content: .media(mediaID: "med_g"), start: .zero, duration: t(3))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_g", "grey.mov", seconds: 3)])
        let ranges = [TimeRange(start: t(0.5), end: t(1)), TimeRange(start: t(2), end: t(2.5))]
        let frames = try await FrameScanner.scan(RenderContext(project: project, folder: media.projectFolder), ranges: ranges, width: 128)
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.first?.time.seconds ?? 0, 0.5, accuracy: 0.001)
        XCTAssertTrue(QualityCheck.frameProblems(frames, in: project).isEmpty, "the jump between the two isn't a flicker")
    }

    func testALongStretchIsReadInPiecesSideBySideWithEveryFrameOnce() async throws {
        let media = try TestMedia()
        // Grey for 24 s, with one white frame at 12 s, across the grid
        // the pieces are cut on.
        try await media.movie("long.mov", seconds: 24, draw: { frame, c in
            TestMedia.fill(c, 0.4, 0.4, 0.4)
            if frame == 360 { TestMedia.fill(c, 1, 1, 1) }
        })
        let clip = Clip(id: "clip_l", content: .media(mediaID: "med_l"), start: .zero, duration: t(24))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_l", "long.mov", seconds: 24)])
        let frames = try await FrameScanner.scan(RenderContext(project: project, folder: media.projectFolder), ranges: [TimeRange(start: t(3), end: t(23))], width: 128)
        XCTAssertEqual(frames.count, 600)
        XCTAssertEqual(frames.first?.time.seconds ?? 0, 3, accuracy: 0.001)
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $1.time > $0.time }, "in order, none twice")
        XCTAssertEqual(QualityCheck.frameProblems(frames, in: project).map(\.start.seconds), [12])
    }

    func testPiecesComeBackInOrderWhateverFinishesFirst() async throws {
        let pieces = (0..<7).map { TimeRange(start: t(Double($0) * 10), end: t(Double($0 + 1) * 10)) }
        let joined = try await FrameScanner.inParallel(pieces, limit: 3) { piece -> [Int] in
            let index = Int(piece.start.seconds / 10)
            try await Task.sleep(nanoseconds: UInt64((7 - index) * 3_000_000))
            return [index * 2, index * 2 + 1]
        }
        XCTAssertEqual(joined, Array(0..<14))
    }
}
