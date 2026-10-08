import CoreImage
import Foundation

/// Which decoder produced an image.
public enum RawRoute: String, Sendable, Codable {
    /// Apple's system RAW engine (`CIRAWFilter`).
    case apple
    /// LibRaw's decode with RawInputKit's development.
    case fallback
}

/// A decoded RAW file.
public struct RawImage: Sendable {
    /// The picture: linear light, in Core Image's working space, rotated upright.
    ///
    /// What the two routes have in common is the encoding, not the look:
    ///
    /// - On the **fallback** route the values are scene-linear: white-balanced and converted
    ///   to sRGB primaries, with no tone curve. Highlights are clipped at 1; colours outside
    ///   sRGB can be negative. Shown as is, it looks dark and flat; see `displayImage`.
    /// - On the **Apple** route it carries Apple's tone mapping, lens corrections and noise
    ///   reduction (unless `appleRendering` is `.linear`), and highlights can exceed 1.
    ///
    /// The routes also differ in what backs the image, which matters once it leaves the
    /// function that opened it:
    ///
    /// - **Apple**: lazy. Pixels are decoded from the file when the image is rendered, so
    ///   the file must stay readable (keep security-scoped access open) until then.
    /// - **Fallback, GPU path**: a Metal texture on the system default device, 8 bytes per
    ///   pixel of GPU memory, held for as long as the image is. Render it with a
    ///   Metal-backed `CIContext`.
    /// - **Fallback, CPU path**: a bitmap in memory, also 8 bytes per pixel.
    public let image: CIImage

    public let route: RawRoute

    /// The decoder in words, for display and logs: "Apple RAW 8", "LibRaw 0.22.2 + Metal",
    /// "LibRaw 0.22.2 CPU".
    public let decoder: String

    public let info: RawInfo

    /// Exposure, in stops, that brings a scene-linear image to a viewable brightness: the
    /// boost that puts the brightest 1% of the frame just under white. Zero on the Apple
    /// route, where the image is already rendered for display.
    public let suggestedExposureEV: Double

    /// True when the fallback developed the frame at half its width and height; see
    /// `RawDecodeOptions.halfSizeAbovePixels`.
    public let isHalfSize: Bool

    /// Wall-clock time `RawInput.open` took. The two routes do different amounts of work
    /// inside `open`: the fallback decodes and develops everything, while Apple's decoder
    /// defers nearly all of it to render time. Use it to compare fallback paths with each
    /// other, not to compare the routes; `rawprobe bench` does that properly.
    public let openSeconds: Double

    public init(
        image: CIImage, route: RawRoute, decoder: String, info: RawInfo, suggestedExposureEV: Double,
        isHalfSize: Bool, openSeconds: Double
    ) {
        self.image = image
        self.route = route
        self.decoder = decoder
        self.info = info
        self.suggestedExposureEV = suggestedExposureEV
        self.isHalfSize = isHalfSize
        self.openSeconds = openSeconds
    }

    /// `image` made ready to show: `suggestedExposureEV` plus `exposureEV` applied in linear
    /// light, then clipped to the displayable range.
    ///
    /// This is a convenience for viewers and tests, not a rendering pipeline. An editor
    /// should take `image` and apply its own exposure, tone curve and gamut handling.
    public func displayImage(exposureEV: Double = 0) -> CIImage {
        var result = image
        let stops = suggestedExposureEV + exposureEV
        if stops != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: stops])
        }
        return result.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }
}
