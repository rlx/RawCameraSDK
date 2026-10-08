import CoreGraphics
import CoreImage
import Foundation
import RawShim

/// Opens camera RAW files.
///
/// `open` tries Apple's RAW engine (`CIRAWFilter`) first and uses the fallback, LibRaw
/// with RawInputKit's development, for files Apple cannot develop.
///
/// All functions are synchronous and thread-safe. A decode can take several seconds, so
/// call them off the main thread.
public enum RawInput {
    /// Decodes a RAW file into a linear-light image.
    ///
    /// - Throws: `RawError`. With `.automatic` routing the error is the fallback's.
    public static func open(_ url: URL, options: RawDecodeOptions = RawDecodeOptions()) throws -> RawImage {
        try open(url, options: options, checksAppleSupport: true)
    }

    /// Opens with Apple's decoder without first testing that it can develop the file. For
    /// benchmarks only. An unsupported file comes back as an image that renders as nothing.
    @_spi(Measurement)
    public static func openAppleUnchecked(_ url: URL, options: RawDecodeOptions = RawDecodeOptions()) throws -> RawImage {
        var options = options
        options.routing = .apple
        return try open(url, options: options, checksAppleSupport: false)
    }

    private static func open(_ url: URL, options: RawDecodeOptions, checksAppleSupport: Bool) throws -> RawImage {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw RawError.fileUnreadable(url) }
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let duration = (clock.now - start).components
            return Double(duration.seconds) + Double(duration.attoseconds) * 1e-18
        }

        let useApple: Bool
        switch options.routing {
        case .automatic:
            useApple = AppleSupport.shared.canDecode(url)
            if !useApple, let handler = options.eventHandler, let header = try? info(url) {
                handler(.appleRejected(camera: header.camera, routine: header.decoderRoutine))
            }
        case .apple:
            // `CIRAWFilter` may return an image that fails silently at render time.
            guard !checksAppleSupport || appleCanDecode(url) else { throw RawError.appleCannotDecode }
            useApple = true
        case .fallback:
            useApple = false
        }

        if useApple {
            let apple = try AppleRawDecoder.decode(url, options: options)
            // LibRaw cannot parse a few files Apple opens, such as JPEG XL DNG.
            let info = (try? info(url)) ?? RawInfo(size: apple.image.extent.size)
            options.eventHandler?(.opened(camera: info.camera, route: .apple, decoder: apple.decoder, seconds: elapsed()))
            return RawImage(
                image: apple.image, route: .apple, isSceneLinear: options.appleRendering == .linear,
                decoder: apple.decoder, info: info, suggestedExposureEV: apple.exposureEV, isHalfSize: false)
        }

        let fallback = try FallbackRawDecoder.decode(url, options: options)
        let image = RawImage(
            image: fallback.image, route: .fallback, fallbackPath: fallback.path, isSceneLinear: true,
            decoder: fallback.decoder, info: fallback.info, suggestedExposureEV: fallback.exposureEV,
            previewDistance: fallback.previewDistance, isHalfSize: fallback.isHalfSize)
        if image.isColorSuspect, let distance = image.previewDistance {
            options.eventHandler?(.colorSuspect(camera: image.info.camera, distance: distance))
        }
        options.eventHandler?(.opened(
            camera: image.info.camera, route: .fallback, decoder: image.decoder, seconds: elapsed()))
        return image
    }

    /// Camera and exposure metadata, read from the file's header only.
    public static func info(_ url: URL) throws -> RawInfo {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw RawError.fileUnreadable(url) }
        do {
            return RawInfo(try LibRawFile(url).info)
        } catch {
            guard let info = RawInfo(imageSourceAt: url) else { throw error }
            return info
        }
    }

    /// The preview the camera embedded in the file, scaled to fit `maxPixelSize` and rotated
    /// upright. Typically a few milliseconds.
    public static func preview(_ url: URL, maxPixelSize: Int = 1024) throws -> CGImage {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw RawError.fileUnreadable(url) }
        return try RawPreview.make(url, maxPixelSize: maxPixelSize)
    }

    /// Whether Apple's decoder develops this file on the running OS. Decodes a small region
    /// of the file, which costs a good fraction of a full decode.
    public static func appleCanDecode(_ url: URL) -> Bool {
        AppleRawDecoder.canDecode(url)
    }

    /// Distance between an image's colours and the embedded preview of the file it came
    /// from, as in `RawImage.previewDistance`. Renders the image at a small size. `nil`
    /// when the file has no embedded preview.
    public static func previewDistance(of image: CIImage, forFileAt url: URL) -> Double? {
        // ImageIO is not used: it can synthesise a preview by developing the file.
        guard let file = try? LibRawFile(url),
              let preview = try? RawPreview.embedded(in: file, maxPixelSize: 512)
        else { return nil }
        return PreviewAgreement.distance(image, preview: preview)
    }

    /// The fallback decoder's version, e.g. "LibRaw 0.22.2".
    public static var fallbackVersion: String { "LibRaw \(FallbackRawDecoder.version)" }
}
