import CoreImage
import Foundation

/// Which decoder produced an image.
public enum RawRoute: String, Sendable, Codable {
    /// Apple's system RAW engine (`CIRAWFilter`).
    case apple
    /// LibRaw's decode with RawInputKit's development.
    case fallback
}

/// Which of the fallback's two development paths produced an image.
public enum RawFallbackPath: String, Sendable, Codable {
    /// Developed by the Metal kernel: plain Bayer sensors.
    case gpu
    /// Developed by the fallback decoder's own CPU pipeline: everything else.
    case cpu
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

    /// On the fallback route, which path developed the image; `nil` on the Apple route.
    public let fallbackPath: RawFallbackPath?

    /// True when `image` is scene-linear: proportional to the light the sensor recorded,
    /// with no tone curve applied. Always true on the fallback route; true on the Apple
    /// route only when it was opened with `appleRendering = .linear`. `rendered(look:)`
    /// gives matching pictures from both routes only for scene-linear images.
    public let isSceneLinear: Bool

    /// The decoder in words, for display and logs: "Apple RAW 8", "LibRaw 0.22.2 + Metal",
    /// "LibRaw 0.22.2 CPU".
    public let decoder: String

    public let info: RawInfo

    /// Exposure, in stops, that brings a scene-linear image to a viewable brightness: the
    /// boost that puts the brightest 1% of the frame just under white. It is measured the
    /// same way on both routes, which is what lets one rendering step serve both. Zero when
    /// the image is not scene-linear, since Apple has then already rendered it for display.
    public let suggestedExposureEV: Double

    /// How far the image's colours sit from the camera's embedded preview, ignoring
    /// brightness: 0 is identical, below 0.05 is typical of a correct decode. `nil` when it
    /// was not measured: on the Apple route, when the file has no preview, or when
    /// `RawDecodeOptions.checksColorAgainstPreview` is off.
    public let previewDistance: Double?

    /// The distance above which a decode deserves a second look.
    public static let suspectPreviewDistance = 0.15

    /// True when the fallback's colours disagree with the camera's own rendering by enough
    /// that the decode is probably wrong: usually a camera LibRaw does not properly know.
    /// The image is still returned, because a tinted picture can be better than none and
    /// only the caller knows which; a viewer should mark it, an importer might refuse it.
    public var isColorSuspect: Bool {
        previewDistance.map { $0 > Self.suspectPreviewDistance } ?? false
    }

    /// True when the fallback developed the frame at half its width and height; see
    /// `RawDecodeOptions.halfSizeAbovePixels`.
    public let isHalfSize: Bool

    public init(
        image: CIImage, route: RawRoute, fallbackPath: RawFallbackPath? = nil, isSceneLinear: Bool,
        decoder: String, info: RawInfo, suggestedExposureEV: Double, previewDistance: Double? = nil,
        isHalfSize: Bool
    ) {
        self.fallbackPath = fallbackPath
        self.previewDistance = previewDistance
        self.image = image
        self.route = route
        self.isSceneLinear = isSceneLinear
        self.decoder = decoder
        self.info = info
        self.suggestedExposureEV = suggestedExposureEV
        self.isHalfSize = isHalfSize
    }

    /// `image` made ready to show: `suggestedExposureEV` plus `exposureEV` applied in linear
    /// light, then clipped to the displayable range.
    ///
    /// No tone curve is applied, so a scene-linear image comes out flat. It shows what the
    /// decoder produced; `rendered(look:)` shows a picture.
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
