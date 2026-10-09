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
        let isMosaic = raw.cfa_kind == RIK_CFA_BAYER.rawValue || raw.cfa_kind == RIK_CFA_XTRANS.rawValue
        func fits(_ path: RawFallbackPath) -> Bool {
            let need = WorkingMemory(
                rawWidth: Int(raw.raw_width), rawHeight: Int(raw.raw_height), width: info.width, height: info.height,
                planes: isMosaic ? 1 : max(1, Int(raw.colors)), isMonochrome: raw.colors == 1,
                // LibRaw halves mosaic sensors only. A four-color mosaic is counted at full
                // size, which errs on the side of refusing.
                halfSize: wantsHalf && isMosaic
            ).megabytes(on: path)
            // Compared as floating point: a limit of `Int.max` means none.
            return need <= Double(options.fallbackMemoryLimitMB)
        }

        if let core = file.developParameters, let metal = MetalDevelop.shared, fits(.gpu) {
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

        guard fits(.cpu) else { throw RawError.exceedsMemoryLimit }
        return try file.withDeveloped(halfSize: wantsHalf) { developed in
            let width = Int(developed.width), height = Int(developed.height)
            let channels = Int(developed.channels)
            guard let source = developed.pixels, width > 0, height > 0 else {
                throw RawError.renderFailed(reason: "the decoder returned an empty image")
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

/// What one fallback decode holds in memory at its peak, worked out from the frame.
///
/// An estimate from buffer sizes, not a measurement. It leaves out LibRaw's small tables
/// and anything Core Image allocates when the image is rendered.
struct WorkingMemory {
    var rawWidth: Int, rawHeight: Int
    /// The picture area at full size.
    var width: Int, height: Int
    /// 16-bit values per pixel in the sensor data: 1 for a mosaic, 3 or 4 for full color.
    var planes: Int
    var isMonochrome: Bool
    var halfSize: Bool

    func megabytes(on path: RawFallbackPath) -> Double {
        let sensor = Double(rawWidth * rawHeight * 2 * planes)
        let pixels = Double(width * height) / (halfSize ? 4 : 1)
        let development: Double
        switch path {
        case .gpu:
            // The mosaic copied into a texture, and a 16-bit float RGBA result.
            development = Double(rawWidth * rawHeight * 2) + pixels * 8
        case .cpu:
            // LibRaw's four-channel working image, its three-channel (or one-channel)
            // result, and the RGBA copy handed to Core Image. All three are alive at once.
            development = pixels * 8 + pixels * (isMonochrome ? 2 : 6) + pixels * 8
        }
        return (sensor + development) / 1_048_576
    }
}
