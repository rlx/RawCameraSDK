import CoreImage
import Foundation
import RawShim

/// The fallback route: LibRaw decodes the sensor data, then one of two paths develops it.
///
/// **GPU path** — plain Bayer sensors, which is most cameras. LibRaw only decompresses;
/// `MetalDevelop` does black level, white balance, demosaicing and colour conversion in a
/// compute kernel. Fast (tenths of a second) and entirely ours to improve.
///
/// **CPU path** — everything else: X-Trans, Foveon, monochrome sensors, already-demosaiced
/// files, and Bayer sensors that need corrections only LibRaw knows (Phase One backs, Fuji
/// SuperCCD). LibRaw's own pipeline develops it, single-threaded. Slow (seconds), but it
/// encodes twenty years of per-camera knowledge that is not worth reimplementing for
/// formats that only reach this code when Apple's decoder has already refused them.
///
/// Both paths produce the same thing: an upright, scene-linear image with sRGB primaries.
/// The shim decides which path a file can take (`rik_info.metal_ready`).
enum FallbackRawDecoder {
    struct Result {
        var image: CIImage
        var decoder: String
        var info: RawInfo
        var exposureEV: Double
        var isHalfSize: Bool
        var previewDistance: Double?
    }

    static let version = String(cString: rik_libraw_version()).replacingOccurrences(of: "-Release", with: "")

    static func decode(_ url: URL, options: RawDecodeOptions) throws -> Result {
        let file = try LibRawFile(url)
        var result = try develop(file, options: options)
        if options.checksColorAgainstPreview,
           let preview = try? RawPreview.embedded(in: file, maxPixelSize: 512) {
            // Compared as it would be shown: exposed and clipped, like the preview.
            let shown = result.image
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: result.exposureEV])
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ])
            result.previewDistance = PreviewAgreement.distance(shown, preview: preview)
        }
        return result
    }

    private static func develop(_ file: LibRawFile, options: RawDecodeOptions) throws -> Result {
        try file.unpack()
        let raw = file.info
        // LibRaw keeps going past truncated or corrupt data and fills the rest with whatever
        // the decoder state yields. A picture that is partly noise is worse than an error.
        guard raw.data_errors == 0 else { throw RawError.corruptData }

        var info = RawInfo(raw)
        let wantsHalf = info.width * info.height > options.halfSizeAbovePixels

        if raw.metal_ready == 1, let metal = MetalDevelop.shared {
            let parameters = MetalDevelop.Parameters(raw)
            // The GPU can fail where the CPU would not: an app in the background may not
            // submit GPU work, a very large frame can exhaust GPU memory, and some old raw
            // planes exceed the texture size limit. None of that is a reason to fail the
            // file, so any error here falls through to LibRaw's development.
            let developed = file.withMosaic { samples, rowBytes in
                try? metal.develop(
                    mosaic: samples, rowBytes: rowBytes, rawWidth: Int(raw.raw_width),
                    rawHeight: Int(raw.raw_height), parameters: parameters, halfSize: wantsHalf)
            }
            if let image = developed ?? nil {
                return Result(
                    image: image.oriented(info.orientation), decoder: "LibRaw \(version) + Metal",
                    info: info, exposureEV: ExposureEstimate.measure(image), isHalfSize: wantsHalf)
            }
        }

        return try file.withDeveloped(halfSize: wantsHalf) { developed in
            let width = Int(developed.width), height = Int(developed.height)
            let channels = Int(developed.channels)
            guard let source = developed.pixels, width > 0, height > 0 else {
                throw RawError.renderFailed(reason: "LibRaw returned an empty image")
            }

            // Core Image has no 16-bit three-channel format, so the pixels are widened to
            // RGBA in a buffer the image can own.
            var rgba = Data(count: width * height * 8)
            rgba.withUnsafeMutableBytes { buffer in
                let out = buffer.bindMemory(to: UInt16.self).baseAddress!
                for pixel in 0..<(width * height) {
                    let r = source[pixel * channels]
                    let g = channels == 3 ? source[pixel * 3 + 1] : r  // monochrome: grey in all three
                    let b = channels == 3 ? source[pixel * 3 + 2] : r
                    out[pixel * 4] = r
                    out[pixel * 4 + 1] = g
                    out[pixel * 4 + 2] = b
                    out[pixel * 4 + 3] = .max
                }
            }
            // The first row of bitmap data is the top of the picture, which is how Core
            // Image reads it too; no flip is needed here, unlike the Metal path.
            let image = CIImage(
                bitmapData: rgba, bytesPerRow: width * 8, size: CGSize(width: width, height: height),
                format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))

            // LibRaw resamples a few sensors (Fuji SuperCCD, non-square pixels), so the frame
            // it returns is the authority on size, not the header.
            let isHalf = developed.is_half_size == 1
            info.width = width * (isHalf ? 2 : 1)
            info.height = height * (isHalf ? 2 : 1)
            return Result(
                image: image.oriented(info.orientation), decoder: "LibRaw \(version) CPU", info: info,
                exposureEV: ExposureEstimate.measure(image), isHalfSize: isHalf)
        }
    }
}
