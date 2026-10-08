import CoreImage
import Foundation

/// The Apple route: a thin layer over `CIRAWFilter`.
///
/// There is deliberately little here. Apple's engine already does demosaicing, lens
/// correction, noise reduction and tone mapping for the cameras it supports, and it gains
/// new cameras with OS updates. The work in this file is knowing when it will *not* work.
enum AppleRawDecoder {
    static func decode(
        _ url: URL, options: RawDecodeOptions
    ) throws -> (image: CIImage, decoder: String, exposureEV: Double) {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RawError.appleCannotDecode }

        if options.appleDecoderVersion == .newest, let newest = newestVersion(of: filter) {
            filter.decoderVersion = newest
        }
        configure(filter, for: options.appleRendering)
        // Keep highlights above reference white instead of clipping them; the caller decides
        // what to do with the headroom.
        filter.extendedDynamicRangeAmount = 1

        guard let image = filter.outputImage, !image.extent.isEmpty, !image.extent.isInfinite else {
            throw RawError.appleCannotDecode
        }
        let exposureEV = options.appleRendering == .linear ? linearExposure(url, version: filter.decoderVersion) : 0
        return (image, "Apple RAW \(filter.decoderVersion.rawValue)", exposureEV)
    }

    private static func configure(_ filter: CIRAWFilter, for rendering: RawDecodeOptions.AppleRendering) {
        guard rendering == .linear else { return }
        // "Boost" is Apple's name for its tone curve; at zero the output is proportional to
        // the scene. Gamut mapping would bend saturated colours toward the display gamut,
        // which is a rendering decision and belongs to whoever renders.
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
    }

    /// Default brightness for Apple's linear output, measured from the pixels by the same
    /// function that measures the fallback's (see `ExposureEstimate.measure`).
    ///
    /// Each decoder has its own idea of where sensor white sits, so a calibration constant
    /// from one says nothing about the other; only the picture says how bright it came out.
    /// Measuring costs a reduced-size decode, paid only by callers who ask for linear output.
    private static func linearExposure(_ url: URL, version: CIRAWDecoderVersion) -> Double {
        guard let filter = CIRAWFilter(imageURL: url) else { return 0 }
        filter.decoderVersion = version
        configure(filter, for: .linear)
        filter.extendedDynamicRangeAmount = 1
        let longEdge = max(filter.nativeSize.width, filter.nativeSize.height)
        guard longEdge > 0 else { return 0 }
        filter.scaleFactor = Float(min(1, 512 / longEdge))
        return filter.outputImage.map(ExposureEstimate.measure) ?? 0
    }

    /// Whether Apple's engine really develops the file.
    ///
    /// `CIRAWFilter(imageURL:)` succeeding proves little. The filter is lazy, and for a
    /// camera it recognises in a compression mode it does not support it can return an
    /// output image that renders as transparent black. The only reliable test is to ask for
    /// pixels and check that something came out.
    ///
    /// It asks for as few as it can: a 64-pixel square from the middle of the frame, at full
    /// scale. That is cheaper than a scaled-down version of the whole picture, because
    /// `scaleFactor` still has the engine demosaic every pixel before shrinking, while a
    /// small region lets Core Image skip the tiles it does not need. The sensor data still
    /// has to be decompressed up to that region, so this is not free: in a fresh process
    /// it adds 0.1 to 0.7 s on an M-series Mac, which is why `RawInput.open` remembers the
    /// answer per camera and mode instead of asking for every file.
    static func canDecode(_ url: URL) -> Bool {
        guard let filter = CIRAWFilter(imageURL: url),
              let image = filter.outputImage, !image.extent.isEmpty, !image.extent.isInfinite
        else { return false }

        let side = Int(min(64, image.extent.width, image.extent.height))
        guard side > 0 else { return false }
        let region = CGRect(
            x: (image.extent.midX - CGFloat(side) / 2).rounded(.down),
            y: (image.extent.midY - CGFloat(side) / 2).rounded(.down),
            width: CGFloat(side), height: CGFloat(side))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        // Rendering into a bitmap is synchronous. `createCGImage` would not do: it defers
        // the work until the image's pixels are first read.
        RenderContext.shared.render(
            image, toBitmap: &pixels, rowBytes: side * 4, bounds: region,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Alpha included: a real decode is opaque, so even a black frame passes.
        return pixels.contains { $0 != 0 }
    }

    /// The highest decoder version the OS offers for this file.
    ///
    /// Versions are strings such as "8" and "8.dng": a number, and a suffix naming a family
    /// (camera files and DNG are versioned separately). Only versions in the family the OS
    /// chose by default are considered. Parsing the strings, instead of naming a constant
    /// such as `.version9`, keeps this compiling and running on OS versions that predate it.
    private static func newestVersion(of filter: CIRAWFilter) -> CIRAWDecoderVersion? {
        func parts(_ version: CIRAWDecoderVersion) -> (number: Int, family: String)? {
            let pieces = version.rawValue.split(separator: ".", maxSplits: 1)
            guard let first = pieces.first, let number = Int(first) else { return nil }
            return (number, pieces.count > 1 ? String(pieces[1]) : "")
        }
        guard let current = parts(filter.decoderVersion) else { return nil }
        return filter.supportedDecoderVersions
            .compactMap { version in parts(version).map { (version: version, parts: $0) } }
            .filter { $0.parts.family == current.family }
            .max { $0.parts.number < $1.parts.number }?.version
    }
}
