import CoreImage
import Foundation

/// The Apple route: a thin layer over `CIRAWFilter`.
enum AppleRawDecoder {
    static func decode(
        _ source: RawSource, options: RawDecodeOptions
    ) throws -> (image: CIImage, decoder: String, version: String, exposureEV: Double) {
        guard let filter = source.makeAppleFilter() else { throw RawError.appleCannotDecode }

        switch options.appleDecoderVersion {
        case .systemDefault:
            break
        case .newest:
            if let newest = newestVersion(of: filter) { filter.decoderVersion = newest }
        case .pinned(let requested):
            // Not assigned blindly: the filter's behavior for a version it does not list is
            // undocumented, and a silently different rendering defeats the pin.
            guard let version = filter.supportedDecoderVersions.first(where: { $0.rawValue == requested }) else {
                throw RawError.appleDecoderVersionUnavailable(
                    requested: requested, available: filter.supportedDecoderVersions.map(\.rawValue))
            }
            filter.decoderVersion = version
        }
        configure(filter, for: options.appleRendering)
        // Keep highlights above reference white.
        filter.extendedDynamicRangeAmount = 1

        guard let image = filter.outputImage, !image.extent.isEmpty, !image.extent.isInfinite else {
            throw RawError.appleCannotDecode
        }
        let version = filter.decoderVersion
        let exposureEV = options.appleRendering == .linear ? linearExposure(source, version: version) : 0
        return (image, "Apple RAW \(version.rawValue)", version.rawValue, exposureEV)
    }

    private static func configure(_ filter: CIRAWFilter, for rendering: RawDecodeOptions.AppleRendering) {
        guard rendering == .linear else { return }
        // Boost is Apple's tone curve. At zero the output is proportional to the scene.
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
    }

    /// Default brightness for Apple's linear output, measured with `ExposureEstimate.measure`
    /// as the fallback's is. Costs a reduced-size decode.
    private static func linearExposure(_ source: RawSource, version: CIRAWDecoderVersion) -> Double {
        guard let filter = source.makeAppleFilter() else { return 0 }
        filter.decoderVersion = version
        configure(filter, for: .linear)
        filter.extendedDynamicRangeAmount = 1
        let longEdge = max(filter.nativeSize.width, filter.nativeSize.height)
        guard longEdge > 0 else { return 0 }
        filter.scaleFactor = Float(min(1, 512 / longEdge))
        return filter.outputImage.map(ExposureEstimate.measure) ?? 0
    }

    /// Whether Apple's engine develops the file, tested by rendering a 64-pixel square from
    /// the middle of the frame.
    ///
    /// `CIRAWFilter` can return an image that renders as transparent black for a camera it
    /// recognizes in a compression mode it does not support. The sensor data is decompressed
    /// up to the tested region, so `RawInput.open` caches a "yes" per camera and mode.
    static func canDecode(_ source: RawSource) -> Bool {
        guard let filter = source.makeAppleFilter(),
              let image = filter.outputImage, !image.extent.isEmpty, !image.extent.isInfinite
        else { return false }

        let side = Int(min(64, image.extent.width, image.extent.height))
        guard side > 0 else { return false }
        let region = CGRect(
            x: (image.extent.midX - CGFloat(side) / 2).rounded(.down),
            y: (image.extent.midY - CGFloat(side) / 2).rounded(.down),
            width: CGFloat(side), height: CGFloat(side))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        // Synchronous. `createCGImage` defers the work until the pixels are first read.
        RenderContext.shared.render(
            image, toBitmap: &pixels, rowBytes: side * 4, bounds: region,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Alpha is included, so an opaque black frame passes.
        return pixels.contains { $0 != 0 }
    }

    /// The highest decoder version the OS offers for this file, within the family the OS
    /// chose by default.
    ///
    /// Versions are strings such as "8" and "8.dng": a number and a family suffix. They are
    /// parsed so that this builds on OS versions that lack the newer constants.
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
