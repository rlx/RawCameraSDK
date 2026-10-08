import CoreImage
import Foundation
import Metal
import RawShim

/// The fallback route: LibRaw decodes the sensor data, then one of two paths develops it.
///
/// GPU path, for plain Bayer sensors: LibRaw decompresses and `MetalDevelop` develops.
/// Takes tenths of a second.
///
/// CPU path, for everything else (X-Trans, Foveon, monochrome, already-demosaiced files,
/// Phase One backs, Fuji SuperCCD): LibRaw develops, single-threaded. Takes seconds.
///
/// Both produce an upright, scene-linear image that keeps colors outside sRGB. The GPU path
/// writes extended linear sRGB as floats, where such colors have components below 0. The
/// CPU path's 16-bit integers cannot go below 0, so it converts to Rec. 2020 primaries
/// instead. The core chooses the path (`rik_info.plain_bayer`).
enum FallbackRawDecoder {
    struct Result {
        var image: CIImage
        var decoder: String
        var info: RawInfo
        var exposureEV: Double
        var isHalfSize: Bool
        var path: RawFallbackPath
        var previewDistance: Double?
        /// The GPU path's output, for `RawImage.makeTexture` to hand over without a copy.
        var texture: MTLTexture?
    }

    static let version = String(cString: rik_libraw_version()).replacingOccurrences(of: "-Release", with: "")

    static func decode(_ source: RawSource, options: RawDecodeOptions) throws -> Result {
        let file = try LibRawFile(source)
        file.useWideGamutOutput()
        file.setMemoryLimit(megabytes: options.fallbackMemoryLimitMB)
        if let isCancelled = options.isCancelled { file.setCancellation(isCancelled) }
        var result = try develop(file, options: options)
        if options.checksColorAgainstPreview,
           let preview = try? RawPreview.embedded(in: file, maxPixelSize: 512) {
            // Exposed and clipped, like the preview.
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
        // LibRaw keeps going past truncated or corrupt data and fills the rest with noise.
        guard raw.data_errors == 0 else { throw RawError.corruptData }

        var info = RawInfo(raw)
        let wantsHalf = info.width * info.height > options.halfSizeAbovePixels

        if let core = file.developParameters, let metal = MetalDevelop.shared {
            let parameters = MetalDevelop.Parameters(core)
            // Any GPU error (backgrounded app, GPU memory, texture size limit) falls through
            // to LibRaw's development.
            do {
                let developed = try file.withMosaic { samples, rowBytes in
                    try metal.develop(
                        mosaic: samples, rowBytes: rowBytes, rawWidth: Int(raw.raw_width),
                        rawHeight: Int(raw.raw_height), parameters: parameters, halfSize: wantsHalf)
                }
                if let developed {
                    let image = developed.image
                    return Result(
                        image: image.oriented(info.orientation), decoder: "LibRaw \(version) + Metal",
                        info: info, exposureEV: ExposureEstimate.measure(image), isHalfSize: wantsHalf, path: .gpu,
                        texture: developed.texture)
                }
            } catch {
                // Reported because the CPU path takes seconds.
                options.eventHandler?(.gpuDevelopFailed(camera: info.camera, reason: error.localizedDescription))
            }
        }

        return try file.withDeveloped(halfSize: wantsHalf) { developed in
            let width = Int(developed.width), height = Int(developed.height)
            let channels = Int(developed.channels)
            guard let source = developed.pixels, width > 0, height > 0 else {
                throw RawError.renderFailed(reason: "the decoder returned an empty image")
            }
            // Compared in megabytes: a limit of `Int.max` would overflow as bytes.
            guard width * height * 8 / 1_048_576 <= options.fallbackMemoryLimitMB else {
                throw RawError.exceedsMemoryLimit
            }

            // Core Image has no 16-bit three-channel format.
            var rgba = Data(count: width * height * 8)
            rgba.withUnsafeMutableBytes { buffer in
                let out = buffer.bindMemory(to: UInt16.self).baseAddress!
                for pixel in 0..<(width * height) {
                    let r = source[pixel * channels]
                    let g = channels == 3 ? source[pixel * 3 + 1] : r  // monochrome: gray in all three
                    let b = channels == 3 ? source[pixel * 3 + 2] : r
                    out[pixel * 4] = r
                    out[pixel * 4 + 1] = g
                    out[pixel * 4 + 2] = b
                    out[pixel * 4 + 3] = .max
                }
            }
            // Row 0 is the top of the picture, as Core Image expects. No flip is needed.
            let image = CIImage(
                bitmapData: rgba, bytesPerRow: width * 8, size: CGSize(width: width, height: height),
                format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.linearITUR_2020))

            // LibRaw resamples a few sensors (Fuji SuperCCD, non-square pixels), so the size
            // is taken from the returned frame.
            let isHalf = developed.is_half_size == 1
            info.width = width * (isHalf ? 2 : 1)
            info.height = height * (isHalf ? 2 : 1)
            return Result(
                image: image.oriented(info.orientation), decoder: "LibRaw \(version) CPU", info: info,
                exposureEV: ExposureEstimate.measure(image), isHalfSize: isHalf, path: .cpu)
        }
    }
}
