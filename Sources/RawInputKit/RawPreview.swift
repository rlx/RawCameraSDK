import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Extracts the preview a camera embeds in its RAW files.
enum RawPreview {
    static func make(_ url: URL, maxPixelSize: Int) throws -> CGImage {
        // LibRaw first: it picks the largest preview. ImageIO can also develop one from the
        // sensor data for files that embed none.
        if let file = try? LibRawFile(url), let image = try? embedded(in: file, maxPixelSize: maxPixelSize) {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions(maxPixelSize, alwaysFromImage: false) as CFDictionary)
        else { throw RawError.noPreview }
        return image
    }

    /// The preview from a file LibRaw already has open.
    static func embedded(in file: LibRawFile, maxPixelSize: Int) throws -> CGImage {
        let orientation = RawInfo(file.info).orientation
        return try file.withThumbnail { thumbnail in
            // Copied: the image may be decoded after LibRaw's buffer is gone.
            let data = Data(bytes: thumbnail.data, count: thumbnail.length)

            if thumbnail.is_jpeg == 1 {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(
                        source, 0, thumbnailOptions(maxPixelSize, alwaysFromImage: true) as CFDictionary)
                else { throw RawError.noPreview }
                // ImageIO has applied the preview's own EXIF orientation if it has one.
                // Untagged previews take the RAW file's orientation.
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let isTagged = properties?[kCGImagePropertyOrientation] != nil
                return isTagged ? image : try fitted(image, orientation, maxPixelSize)
            }

            // An uncompressed RGB bitmap. The shim has checked that `length` covers
            // width * height * 3 bytes.
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

    /// Applies the RAW file's orientation and the size limit.
    private static func fitted(
        _ image: CGImage, _ orientation: CGImagePropertyOrientation, _ maxPixelSize: Int
    ) throws -> CGImage {
        let scale = min(1, CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height)))
        guard orientation != .up || scale < 1 else { return image }
        let oriented = CIImage(cgImage: image)
            .oriented(orientation)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Rounded down to stay within the requested size.
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
            // "If absent" lets ImageIO prefer a thumbnail the file already contains.
            alwaysFromImage
                ? kCGImageSourceCreateThumbnailFromImageAlways
                : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        ]
    }
}
