import CoreGraphics
import CoreText
import Foundation
import ImageIO
import TandemCore
import UniformTypeIdentifiers

/// Lays rendered frames out on one PNG, each with its time under it, for
/// `tandem frames`. Agents used to loop `tandem frame` and stitch the PNGs
/// with ffmpeg, which broke on drawtext escaping and on file names with
/// colons, so this draws with Core Graphics and nothing else.
enum ContactSheet {
    static let defaultTileWidth = 480
    static let tileWidths = 64...1920
    /// Enough for every 5 s of four minutes. Past this the tiles get too
    /// small to read or the sheet too big to look at in one go.
    static let maxTiles = 48

    struct Layout: Equatable {
        static let gap = 8
        /// The strip under each tile that holds its time, so the label never
        /// covers a caption or lower third at the bottom of the frame.
        static let labelHeight = 28

        var columns: Int
        var rows: Int
        var tileWidth: Int
        var tileHeight: Int

        init(count: Int, tileWidth: Int, canvas: CGSize) {
            let aspect = canvas.height / max(canvas.width, 1)
            self.tileWidth = tileWidth
            tileHeight = max(1, Int((Double(tileWidth) * aspect).rounded()))
            // Enough columns for the whole sheet to come out about 16:9, so
            // it fits a screen: landscape tiles go about four to a row,
            // portrait ones about seven. The slack keeps a perfect square
            // like 4 tiles from tipping into an extra column.
            let ideal = (Double(count) * aspect * 16 / 9).squareRoot()
            columns = max(1, min(count, Int((ideal - 0.001).rounded(.up))))
            rows = max(1, (count + columns - 1) / columns)
        }

        var cellHeight: Int { tileHeight + Self.labelHeight }
        var width: Int { columns * tileWidth + (columns + 1) * Self.gap }
        var height: Int { rows * cellHeight + (rows + 1) * Self.gap }

        /// Where tile `index` goes, in Core Graphics coordinates (origin at
        /// the bottom left), above its label strip.
        func tileRect(_ index: Int) -> CGRect {
            let column = index % columns, row = index / columns
            let x = Self.gap + column * (tileWidth + Self.gap)
            let top = Self.gap + row * (cellHeight + Self.gap)
            return CGRect(x: x, y: height - top - tileHeight, width: tileWidth, height: tileHeight)
        }
    }

    static func compose(_ frames: [(time: Time, png: Data)], layout: Layout) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: layout.width, height: layout.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ServiceError(.internalError, "Couldn't make a \(layout.width)x\(layout.height) contact sheet.")
        }
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        context.interpolationQuality = .high
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 16, nil)
        for (index, frame) in frames.enumerated() {
            let tile = layout.tileRect(index)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(tile)
            guard let source = CGImageSourceCreateWithData(frame.png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ServiceError(.internalError, "The frame at \(frame.time) didn't render as a picture.")
            }
            context.draw(image, in: fitted(CGSize(width: image.width, height: image.height), in: tile))
            drawLabel(frame.time.description, font: font, in: CGRect(x: tile.minX, y: tile.minY - CGFloat(Layout.labelHeight), width: tile.width, height: CGFloat(Layout.labelHeight)), context: context)
        }
        guard let sheet = context.makeImage() else {
            throw ServiceError(.internalError, "Couldn't finish the contact sheet.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ServiceError(.internalError, "Couldn't write the contact sheet as a PNG.")
        }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ServiceError(.internalError, "Couldn't write the contact sheet as a PNG.")
        }
        return data as Data
    }

    /// The picture scaled to fit the tile, centred, in case a renderer
    /// hands back a frame of another shape.
    static func fitted(_ size: CGSize, in tile: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return tile }
        let scale = min(tile.width / size.width, tile.height / size.height)
        let fit = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: tile.midX - fit.width / 2, y: tile.midY - fit.height / 2, width: fit.width, height: fit.height)
    }

    private static func drawLabel(_ text: String, font: CTFont, in strip: CGRect, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: strip.minX + 2, y: strip.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}
