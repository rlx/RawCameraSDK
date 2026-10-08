import CoreImage
import Foundation

/// A rendering of scene-linear data into a picture: a tone curve and, optionally, a style.
///
/// Applied identically whichever decoder produced the data. Baked into a 3D lookup table
/// and applied with `CIColorCubeWithColorSpace`.
public struct RawLook: Hashable, Sendable {
    /// Steepness of the S-curve around middle grey. 0 leaves tones unchanged. 4 to 6 is the
    /// contrast of a typical in-camera JPEG.
    public var contrast: Double
    /// 1 is unchanged, 0 is monochrome.
    public var saturation: Double
    /// How far black is lifted off zero, as a fraction of full scale. 0.03 is noticeable,
    /// 0.08 is heavy.
    public var fade: Double
    /// RGB added to the darkest tones, falling off toward the midtones.
    public var shadowTint: SIMD3<Double>
    /// RGB added to the brightest tones, falling off toward the midtones.
    public var highlightTint: SIMD3<Double>

    public init(
        contrast: Double, saturation: Double = 1, fade: Double = 0,
        shadowTint: SIMD3<Double> = .zero, highlightTint: SIMD3<Double> = .zero
    ) {
        self.contrast = contrast
        self.saturation = saturation
        self.fade = fade
        self.shadowTint = shadowTint
        self.highlightTint = highlightTint
    }

    /// A plain rendering with the contrast of a camera JPEG.
    public static let neutral = RawLook(contrast: 4.5, saturation: 1.05)

    /// A film-style rendering: softer saturation, lifted blacks, teal shadows, warm highlights.
    public static let film = RawLook(
        contrast: 5, saturation: 0.86, fade: 0.035,
        shadowTint: SIMD3(-0.012, 0.008, 0.022), highlightTint: SIMD3(0.022, 0.008, -0.02))
}

extension RawLook {
    /// Edge length of the lookup table.
    static let cubeSize = 33

    /// Applies the look to one colour. Input and output are sRGB-encoded, 0...1.
    func apply(_ color: SIMD3<Double>) -> SIMD3<Double> {
        var c = color

        // A logistic curve through middle grey, rescaled so black and white stay fixed.
        if contrast > 0 {
            let pivot = 0.46  // 18% grey, sRGB-encoded
            func logistic(_ x: Double) -> Double { 1 / (1 + exp(-contrast * (x - pivot))) }
            let low = logistic(0), high = logistic(1)
            for i in 0..<3 { c[i] = (logistic(c[i]) - low) / (high - low) }
        }

        let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        c = SIMD3(repeating: luma) + (c - SIMD3(repeating: luma)) * saturation

        // Squared weights fade each tint out before the midtones.
        let shadows = (1 - luma) * (1 - luma), highlights = luma * luma
        c += shadowTint * shadows + highlightTint * highlights

        c = SIMD3(repeating: fade) + c * (1 - fade)
        return c.clamped(lowerBound: .zero, upperBound: .one)
    }

    /// Lookup-table data in Core Image's layout: RGBA floats, red varying fastest, then
    /// green, then blue.
    func cubeData() -> Data {
        let n = Self.cubeSize
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = apply(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1))
                    values += [Float(out.x), Float(out.y), Float(out.z), 1]
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Each distinct look's table is built once per process.
    private static let cache = LookCache()

    func filter(on image: CIImage) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize,
            "inputCubeData": Self.cache.data(for: self),
            // The table was built on sRGB-encoded values.
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
    }
}

private final class LookCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [RawLook: Data] = [:]  // guarded by `lock`

    func data(for look: RawLook) -> Data {
        lock.withLock {
            if let table = tables[look] { return table }
            let table = look.cubeData()
            tables[look] = table
            return table
        }
    }
}

extension RawImage {
    /// The picture with exposure and then a look applied. Both routes give matching
    /// pictures only when the image is scene-linear (`isSceneLinear`).
    ///
    /// - Parameter exposureEV: stops added to `suggestedExposureEV`.
    public func rendered(look: RawLook = .neutral, exposureEV: Double = 0) -> CIImage {
        var result = image
        let stops = suggestedExposureEV + exposureEV
        if stops != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: stops])
        }
        // The lookup clamps its input to 0...1, which clips the highlights.
        return look.filter(on: result)
    }
}
