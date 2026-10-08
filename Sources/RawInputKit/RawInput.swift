import CoreGraphics
import Foundation
import RawShim

/// Opens camera RAW files.
///
/// RawInputKit has two decoders behind one call:
///
/// - **Apple's** system RAW engine (`CIRAWFilter`). It covers most current cameras, applies
///   Apple's look (tone curve, lens correction, noise reduction) and costs nothing to ship.
/// - **The fallback**: LibRaw decodes the sensor data and RawInputKit develops it, on the GPU
///   for ordinary Bayer sensors and with LibRaw's own CPU pipeline for everything else. It
///   opens formats Apple never supported, and its output is deliberately plain.
///
/// `open` picks between them per file. Neither decoder is a superset of the other, so the
/// order matters: Apple first, because it is the better result whenever it works.
///
/// All functions are synchronous and safe to call from any thread, including several at
/// once. Decoding a large file takes from a tenth of a second to several seconds, so call
/// them off the main thread.
public enum RawInput {
    /// Decodes a RAW file into a linear-light image an editor can work on.
    ///
    /// - Throws: `RawError`. With `.automatic` routing the error describes why the fallback
    ///   failed, since that is the decoder of last resort.
    public static func open(_ url: URL, options: RawDecodeOptions = RawDecodeOptions()) throws -> RawImage {
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
        case .apple:
            // An explicit request is still checked. `CIRAWFilter` is lazy: for a file it
            // cannot develop it may return an image that only fails, silently, at render time.
            guard appleCanDecode(url) else { throw RawError.appleCannotDecode }
            useApple = true
        case .fallback:
            useApple = false
        }

        if useApple {
            let apple = try AppleRawDecoder.decode(url, options: options)
            // Metadata is best effort here. LibRaw cannot parse a few files Apple opens
            // (JPEG XL DNG, for one), and a decodable image is worth more than its EXIF.
            let info = (try? info(url)) ?? RawInfo(size: apple.image.extent.size)
            return RawImage(
                image: apple.image, route: .apple, decoder: apple.decoder, info: info,
                suggestedExposureEV: 0, isHalfSize: false, openSeconds: elapsed())
        }

        let fallback = try FallbackRawDecoder.decode(url, options: options)
        return RawImage(
            image: fallback.image, route: .fallback, decoder: fallback.decoder, info: fallback.info,
            suggestedExposureEV: fallback.exposureEV, isHalfSize: fallback.isHalfSize, openSeconds: elapsed())
    }

    /// Camera and exposure metadata. Reads the file's header only; no sensor data is decoded.
    public static func info(_ url: URL) throws -> RawInfo {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw RawError.fileUnreadable(url) }
        do {
            return RawInfo(try LibRawFile(url).info)
        } catch {
            // LibRaw knows far more about RAW metadata than ImageIO, so it goes first.
            guard let info = RawInfo(imageSourceAt: url) else { throw error }
            return info
        }
    }

    /// The preview the camera embedded in the file, scaled to fit `maxPixelSize` and rotated
    /// upright. Typically a few milliseconds, which is what makes a browsable grid possible
    /// before any file is developed.
    public static func preview(_ url: URL, maxPixelSize: Int = 1024) throws -> CGImage {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw RawError.fileUnreadable(url) }
        return try RawPreview.make(url, maxPixelSize: maxPixelSize)
    }

    /// Whether Apple's decoder develops this file on the running OS.
    ///
    /// The answer comes from decoding a small region of the file, not from a list of
    /// cameras: support depends on the compression mode as well as the model, changes with
    /// OS updates, and Apple's published list records neither precisely.
    ///
    /// This always tests the file itself and costs a good fraction of a full decode.
    /// `open` with `.automatic` routing is cheaper over many files: it tests the first file
    /// of each camera and mode and reuses the answer for the rest.
    public static func appleCanDecode(_ url: URL) -> Bool {
        AppleRawDecoder.canDecode(url)
    }

    /// The fallback decoder's version, e.g. "LibRaw 0.22.2".
    public static var fallbackVersion: String { "LibRaw \(FallbackRawDecoder.version)" }

    /// How many camera models the fallback decoder has tables for. An upper bound on what
    /// it develops correctly, not a guarantee: see the coverage notes in the README.
    public static var fallbackCameraCount: Int { Int(rik_camera_count()) }
}
