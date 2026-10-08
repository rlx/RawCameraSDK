import CoreImage
import CoreText
import Foundation
import RawInputKit

/// Lays images out in a captioned grid and writes them as one JPEG.
enum ContactSheet {
    struct Cell {
        enum Framing {
            /// Scaled to the cell's width.
            case whole
            /// The centre at one image pixel per sheet pixel.
            case centreCrop
        }

        var caption: String?
        var image: CIImage
        var framing = Framing.whole
    }

    private static let gutter: CGFloat = 12
    private static let captionHeight: CGFloat = 30

    /// - Parameter cellSize: every cell is this wide; `whole` cells take their height from
    ///   the first cell's aspect ratio, `centreCrop` cells use `cellSize.height`.
    static func write(rows: [[Cell]], cellSize: CGSize, to output: URL) throws {
        guard let first = rows.first?.first else { return }
        let wholeHeight = (cellSize.width * first.image.extent.height / first.image.extent.width).rounded()
        func height(of row: [Cell]) -> CGFloat {
            let picture = row.contains { $0.framing == .whole } ? wholeHeight : cellSize.height
            return picture + (row.contains { $0.caption != nil } ? captionHeight : 0)
        }
        let columns = rows.map(\.count).max() ?? 1
        let size = CGSize(
            width: CGFloat(columns) * (cellSize.width + gutter) + gutter,
            height: rows.reduce(gutter) { $0 + height(of: $1) + gutter })

        let context = CIContext()
        guard let canvas = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RawError.renderFailed(reason: "could not create the sheet") }
        canvas.setFillColor(CGColor(gray: 0.07, alpha: 1))
        canvas.fill(CGRect(origin: .zero, size: size))
        canvas.interpolationQuality = .high

        // Core Graphics has a bottom-left origin, so rows are placed from the top down.
        var top = size.height - gutter
        for row in rows {
            let rowHeight = height(of: row)
            let hasCaption = row.contains { $0.caption != nil }
            for (index, cell) in row.enumerated() {
                let x = gutter + CGFloat(index) * (cellSize.width + gutter)
                let pictureHeight = rowHeight - (hasCaption ? captionHeight : 0)
                let extent = cell.image.extent
                let source = cell.framing == .whole
                    ? extent
                    : CGRect(
                        x: extent.midX - cellSize.width / 2, y: extent.midY - pictureHeight / 2,
                        width: cellSize.width, height: pictureHeight)
                guard let picture = context.createCGImage(cell.image, from: source) else {
                    throw RawError.renderFailed(reason: "could not draw a cell of the sheet")
                }
                canvas.draw(picture, in: CGRect(x: x, y: top - rowHeight, width: cellSize.width, height: pictureHeight))

                if let caption = cell.caption {
                    let text = NSAttributedString(string: caption, attributes: [
                        kCTFontAttributeName as NSAttributedString.Key:
                            CTFontCreateWithName("Helvetica Neue" as CFString, 17, nil),
                        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.92, alpha: 1),
                    ])
                    canvas.textPosition = CGPoint(x: x, y: top - captionHeight + 9)
                    CTLineDraw(CTLineCreateWithAttributedString(text), canvas)
                }
            }
            top -= rowHeight + gutter
        }

        guard let sheet = canvas.makeImage() else { throw RawError.renderFailed(reason: "could not finish the sheet") }
        try context.writeJPEGRepresentation(
            of: CIImage(cgImage: sheet), to: output, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.86])
    }
}
