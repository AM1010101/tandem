import CoreGraphics
import ImageIO
import XCTest
@testable import TandemAPI
@testable import TandemCore

/// `tandem frames`: several frames rendered the way `frame` renders them,
/// laid out on one labelled contact sheet.
final class ContactSheetTests: XCTestCase {
    func image(_ data: Data) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    }

    func testTheLayoutAimsForAWideSheet() {
        let landscape = ContactSheet.Layout(count: 12, tileWidth: 480, canvas: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(landscape.columns, 4)
        XCTAssertEqual(landscape.rows, 3)
        XCTAssertEqual(landscape.tileHeight, 270)
        XCTAssertEqual(landscape.width, 4 * 480 + 5 * ContactSheet.Layout.gap)
        XCTAssertEqual(landscape.height, 3 * (270 + ContactSheet.Layout.labelHeight) + 4 * ContactSheet.Layout.gap)

        let portrait = ContactSheet.Layout(count: 12, tileWidth: 240, canvas: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(portrait.columns, 7, "tall tiles go more to a row")
        XCTAssertEqual(portrait.rows, 2)
        XCTAssertEqual(portrait.tileHeight, 427)

        let one = ContactSheet.Layout(count: 1, tileWidth: 480, canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(one.columns, 1)
        XCTAssertEqual(one.rows, 1)
    }

    func testFramesMakesOneSheetOfTheTimesInOrder() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await FramesRequest(times: [t(21), t(2), t(12), t(2)], width: 200, output: "sheets/s.png").run(on: h.service, context: h.context)
        XCTAssertEqual(result.times, [t(2), t(12), t(21)], "sorted, once each")
        XCTAssertEqual(renderer.frames.all.map(\.time), [t(2), t(12), t(21)])
        XCTAssertEqual(renderer.frames.all.first?.maxSize?.width, 200)
        XCTAssertEqual(result.path, h.folder.file("sheets/s.png").standardizedFileURL.path)

        let settings = h.service.coordinator.project.settings
        let layout = ContactSheet.Layout(count: 3, tileWidth: 200, canvas: CGSize(width: settings.width, height: settings.height))
        let sheet = try image(try Data(contentsOf: h.folder.file("sheets/s.png")))
        XCTAssertEqual(sheet.width, layout.width)
        XCTAssertEqual(sheet.height, layout.height)
        XCTAssertTrue(result.readableText.contains("3 frames"), result.readableText)
        XCTAssertTrue(result.readableText.contains("00:02.000"), result.readableText)
    }

    func testEveryStepsThroughTheRange() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let ranged = try await FramesRequest(every: t(5), from: t(10), to: t(20)).run(on: h.service, context: h.context)
        XCTAssertEqual(ranged.times, [t(10), t(15), t(20)])
        XCTAssertNotNil(ranged.png, "no output: the sheet comes back as base64")

        // Without a range: the whole timeline (60 s), not the empty frame at the end.
        let whole = try await FramesRequest(every: t(15)).run(on: h.service, context: h.context)
        XCTAssertEqual(whole.times, [t(0), t(15), t(30), t(45)])

        // Times and a step together.
        let both = try await FramesRequest(times: [t(1)], every: t(10), from: t(40)).run(on: h.service, context: h.context)
        XCTAssertEqual(both.times, [t(1), t(40), t(50)])
    }

    func testMistakesSaySo() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        assertServiceError(.badRequest) { _ = try h.service.prepareFrames(FramesRequest()) }
        assertServiceError(.badRequest) { _ = try h.service.prepareFrames(FramesRequest(times: [t(-1)])) }
        assertServiceError(.badRequest) { _ = try h.service.prepareFrames(FramesRequest(times: [t(1)], from: t(0))) }
        assertServiceError(.badRequest) { _ = try h.service.prepareFrames(FramesRequest(every: t(0))) }
        assertServiceError(.badRequest) { _ = try h.service.prepareFrames(FramesRequest(times: [t(1)], width: 10)) }
        assertServiceError(.badRequest) { _ = try h.service.prepareFrames(FramesRequest(every: t(10), from: t(30), to: t(20))) }
        assertServiceError(.invalid) { _ = try h.service.prepareFrames(FramesRequest(times: [t(1)], output: "Decision Models.tandem")) }
        do {
            _ = try h.service.prepareFrames(FramesRequest(every: t(0.5)))
            XCTFail("120 frames is too many for one sheet")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("120 frames"), error.message)
            XCTAssertTrue(error.message.contains("at most \(ContactSheet.maxTiles)"), error.message)
        }
    }

    func testTheRequestDecodesTimesAsSecondsOrClockText() throws {
        let request = try ServiceJSON.decodeRequest(FramesRequest.self, from: Data(#"{"times": [12, "01:02.500"], "every": "5", "width": 300}"#.utf8))
        XCTAssertEqual(request.times, [t(12), t(62.5)])
        XCTAssertEqual(request.every, t(5))
        XCTAssertEqual(request.width, 300)
        XCTAssertThrowsError(try ServiceJSON.decodeRequest(FramesRequest.self, from: Data(#"{"times": ["soon"]}"#.utf8)))
    }

    func testTheSheetComesBackAsAnImageOverMCP() async throws {
        let mcp = try MCPHarness()
        let sheet = try await mcp.tool(1, "frames", #"{"times": [2, "0:12"]}"#)
        let content = try XCTUnwrap(sheet[json: "result"]?[json: "content"]?.testArray)
        XCTAssertEqual(content.first?[json: "type"], .string("image"))
        XCTAssertEqual(content.first?[json: "mimeType"], .string("image/png"))
        let data = try XCTUnwrap(content.first?[json: "data"]?.testString.flatMap { Data(base64Encoded: $0) })
        XCTAssertGreaterThan(try image(data).width, 2 * ContactSheet.defaultTileWidth)
        await mcp.close()
    }
}
