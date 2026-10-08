import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Extracts the preview a camera embeds in its RAW files.
///
/// Nearly every RAW file carries a JPEG the camera rendered at capture time, often at full
/// resolution. Reading it takes milliseconds and no sensor decoding, and it shows the
/// picture as the photographer saw it on the camera, which makes it the right thing to put
/// in a grid or a culling view.
enum RawPreview {
    static func make(_ url: URL, maxPixelSize: Int) throws -> CGImage {
        // LibRaw first: it picks the largest of a file's several previews and understands
        // formats ImageIO does not. ImageIO is the backstop, and can also develop a preview
        // from the sensor data for the few files that embed none.
        if let image = try? embedded(url, maxPixelSize: maxPixelSize) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions(maxPixelSize, alwaysFromImage: false) as CFDictionary)
        else { throw RawError.noPreview }
        return image
    }

    private static func embedded(_ url: URL, maxPixelSize: Int) throws -> CGImage {
        let file = try LibRawFile(url)
        let orientation = RawInfo(file.info).orientation
        return try file.withThumbnail { thumbnail in
            // Copied, because the image may be decoded lazily after LibRaw's buffer is gone.
            let data = Data(bytes: thumbnail.data, count: thumbnail.length)

            if thumbnail.is_jpeg == 1 {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(
                        source, 0, thumbnailOptions(maxPixelSize, alwaysFromImage: true) as CFDictionary)
                else { throw RawError.noPreview }
                // Two conventions exist. Some cameras tag the preview with its own EXIF
                // orientation, which ImageIO has just applied. Others store it unrotated and
                // untagged, expecting the RAW file's orientation to be used for both.
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let isTagged = properties?[kCGImagePropertyOrientation] != nil
                return isTagged ? image : try fitted(image, orientation, maxPixelSize)
            }

            // A few older formats embed an uncompressed RGB bitmap. The shim has already
            // checked that `length` covers width * height * 3 bytes.
            let width = Int(thumbnail.width), height = Int(thumbnail.height)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                    bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw RawError.noPreview }
            return try fitted(image, orientation, maxPixelSize)
        }
    }

    /// Applies the RAW file's orientation and the size limit to a preview that has neither.
    private static func fitted(
        _ image: CGImage, _ orientation: CGImagePropertyOrientation, _ maxPixelSize: Int
    ) throws -> CGImage {
        let scale = min(1, CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height)))
        guard orientation != .up || scale < 1 else { return image }
        let oriented = CIImage(cgImage: image)
            .oriented(orientation)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Rounded down, so the result never exceeds the requested size by a pixel.
        let bounds = CGRect(
            x: oriented.extent.minX, y: oriented.extent.minY,
            width: oriented.extent.width.rounded(.down), height: oriented.extent.height.rounded(.down))
        guard let result = RenderContext.shared.createCGImage(oriented, from: bounds) else {
            throw RawError.renderFailed(reason: "could not rotate the embedded preview")
        }
        return result
    }

    private static func thumbnailOptions(_ maxPixelSize: Int, alwaysFromImage: Bool) -> [CFString: Any] {
        [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // "Always" decodes the given JPEG itself; "if absent" lets ImageIO prefer a
            // thumbnail the file already contains.
            alwaysFromImage
                ? kCGImageSourceCreateThumbnailFromImageAlways
                : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        ]
    }
}
