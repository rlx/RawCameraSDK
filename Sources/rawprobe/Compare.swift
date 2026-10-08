import CoreImage
import CoreText
import Foundation
import RawInputKit

/// `rawprobe compare`: one picture that puts both decoders' output for a file next to
/// each other, so differences in look and detail can be judged by eye.
///
/// Layout: Apple on the left, the fallback on the right; the whole frame on top and a
/// 1:1 crop from the centre underneath.
enum Compare {
    private static let columnWidth: CGFloat = 900
    private static let cropHeight: CGFloat = 520
    private static let gutter: CGFloat = 12
    private static let captionHeight: CGFloat = 34

    static func run(input: URL, output: URL) throws {
        var options = RawDecodeOptions()
        // Compare like with like: never let the pixel budget halve the fallback.
        options.halfSizeAbovePixels = .max
        options.routing = .apple
        let apple = try RawInput.open(input, options: options)
        options.routing = .fallback
        let fallback = try RawInput.open(input, options: options)

        let columns = [
            (title: "\(apple.decoder)", image: apple.displayImage()),
            (title: "\(fallback.decoder)", image: fallback.displayImage()),
        ]
        let frameHeight = (columnWidth * columns[0].image.extent.height / columns[0].image.extent.width).rounded()
        let size = CGSize(
            width: columnWidth * 2 + gutter * 3,
            height: captionHeight + frameHeight + gutter + cropHeight + gutter)

        let context = CIContext()
        guard let canvas = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RawError.renderFailed(reason: "could not draw the comparison") }
        canvas.setFillColor(CGColor(gray: 0.07, alpha: 1))
        canvas.fill(CGRect(origin: .zero, size: size))

        for (index, column) in columns.enumerated() {
            let x = gutter + CGFloat(index) * (columnWidth + gutter)
            // Core Graphics has its origin at the bottom-left, so rows are placed from the top down.
            let frameRect = CGRect(x: x, y: size.height - captionHeight - frameHeight, width: columnWidth, height: frameHeight)
            let cropRect = CGRect(x: x, y: gutter, width: columnWidth, height: cropHeight)

            let whole = column.image
            guard let frame = context.createCGImage(whole, from: whole.extent),
                  let crop = context.createCGImage(whole, from: CGRect(
                    x: whole.extent.midX - columnWidth / 2, y: whole.extent.midY - cropHeight / 2,
                    width: columnWidth, height: cropHeight))
            else { throw RawError.renderFailed(reason: "could not draw the comparison") }
            canvas.interpolationQuality = .high
            canvas.draw(frame, in: frameRect)
            canvas.draw(crop, in: cropRect)

            let caption = NSAttributedString(string: column.title, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica Neue" as CFString, 18, nil),
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.92, alpha: 1),
            ])
            canvas.textPosition = CGPoint(x: x, y: size.height - captionHeight + 10)
            CTLineDraw(CTLineCreateWithAttributedString(caption), canvas)
        }

        guard let composite = canvas.makeImage() else { throw RawError.renderFailed(reason: "could not draw the comparison") }
        try context.writeJPEGRepresentation(
            of: CIImage(cgImage: composite), to: output, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.86])
        print("\(apple.info.camera): \(columns[0].title) vs \(columns[1].title) -> \(output.lastPathComponent)")
    }
}
