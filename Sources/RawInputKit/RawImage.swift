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
    /// The Metal kernel, for plain Bayer sensors.
    case gpu
    /// LibRaw's CPU pipeline, for everything else.
    case cpu
}

/// A decoded RAW file.
public struct RawImage: Sendable {
    /// The picture: linear light, in Core Image's working space, rotated upright.
    ///
    /// Fallback route: scene-linear with sRGB primaries and no tone curve. Highlights are
    /// clipped at 1 and colours outside sRGB can be negative. The GPU path backs it with a
    /// Metal texture on the system default device, the CPU path with a bitmap. Both take
    /// 8 bytes per pixel.
    ///
    /// Apple route: carries Apple's tone mapping, lens corrections and noise reduction
    /// unless `appleRendering` is `.linear`. Highlights can exceed 1. Pixels are decoded at
    /// render time, so the file must stay readable until then.
    public let image: CIImage

    public let route: RawRoute

    /// The fallback path that developed the image. `nil` on the Apple route.
    public let fallbackPath: RawFallbackPath?

    /// True when `image` is scene-linear, with no tone curve applied. Always true on the
    /// fallback route. On the Apple route, true only with `appleRendering = .linear`.
    public let isSceneLinear: Bool

    /// For display and logs: "Apple RAW 8", "LibRaw 0.22.2 + Metal", "LibRaw 0.22.2 CPU".
    public let decoder: String

    public let info: RawInfo

    /// Exposure, in stops, that puts the brightest 1% of a scene-linear frame just under
    /// white. Zero when the image is not scene-linear.
    public let suggestedExposureEV: Double

    /// Distance between the image's colours and the camera's embedded preview, ignoring
    /// brightness. 0 is identical and below 0.05 is typical of a correct decode. `nil` on
    /// the Apple route, when the file has no preview, or when
    /// `RawDecodeOptions.checksColorAgainstPreview` is off.
    public let previewDistance: Double?

    /// The distance above which `isColorSuspect` is true.
    public static let suspectPreviewDistance = 0.15

    /// True when the fallback's colours are far enough from the camera's preview that the
    /// decode is probably wrong. The image is still returned.
    public var isColorSuspect: Bool {
        previewDistance.map { $0 > Self.suspectPreviewDistance } ?? false
    }

    /// True when the fallback developed the frame at half its width and height.
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

    /// `image` with `suggestedExposureEV` plus `exposureEV` applied in linear light, then
    /// clipped to the displayable range. No tone curve is applied.
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
