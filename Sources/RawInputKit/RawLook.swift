import CoreImage
import Foundation

/// A rendering of scene-linear data into a picture: a tone curve and, optionally, a style.
///
/// The decoders stop at scene-linear, which is the right place for a decoder to stop and
/// the wrong thing to show anyone. Something has to turn it into a picture, and if the two
/// decoders each used their own something, a gallery would show two visibly different
/// kinds of photograph depending on which decoder happened to open each file.
///
/// `RawLook` is that step, applied identically whichever decoder produced the data. It is
/// deliberately small: one contrast curve, saturation, a tint for shadows and highlights,
/// and a fade. That is enough to prove that the decoders' output is interchangeable as
/// input to an editor, and to carry a recognisable style. It is not a film-emulation
/// engine, and a real product would put its own pipeline here.
///
/// A look is baked into a 3D lookup table and applied with `CIColorCubeWithColorSpace`, so
/// it costs one texture fetch per pixel however elaborate the maths that built it.
public struct RawLook: Hashable, Sendable {
    /// Steepness of the S-curve around middle grey. 0 leaves tones as they are; 4 to 6 is
    /// the contrast of a typical in-camera JPEG.
    public var contrast: Double
    /// 1 is unchanged, 0 is monochrome.
    public var saturation: Double
    /// How far black is lifted off zero, as a fraction of full scale. Faded film has milky
    /// shadows; 0.03 is noticeable, 0.08 is heavy.
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

    /// A plain rendering: the contrast of a camera JPEG and nothing else.
    public static let neutral = RawLook(contrast: 4.5, saturation: 1.05)

    /// A film-style rendering: softer saturation, lifted blacks, shadows leaning teal and
    /// highlights leaning warm.
    public static let film = RawLook(
        contrast: 5, saturation: 0.86, fade: 0.035,
        shadowTint: SIMD3(-0.012, 0.008, 0.022), highlightTint: SIMD3(0.022, 0.008, -0.02))
}

extension RawLook {
    /// Edge length of the lookup table. 33 is the film industry's usual size: trilinear
    /// interpolation between 33 points per axis is indistinguishable from the exact curve
    /// for transforms as smooth as these.
    static let cubeSize = 33

    /// What the look does to one colour. Input and output are sRGB-encoded, 0...1.
    ///
    /// The curve is applied to encoded values, not linear ones, because encoded values are
    /// roughly perceptual: a contrast curve that is symmetric around middle grey there looks
    /// symmetric to the eye.
    func apply(_ color: SIMD3<Double>) -> SIMD3<Double> {
        var c = color

        // Contrast: a logistic curve through middle grey, rescaled so that black stays
        // black and white stays white.
        if contrast > 0 {
            let pivot = 0.46  // 18% grey, sRGB-encoded
            func logistic(_ x: Double) -> Double { 1 / (1 + exp(-contrast * (x - pivot))) }
            let low = logistic(0), high = logistic(1)
            for i in 0..<3 { c[i] = (logistic(c[i]) - low) / (high - low) }
        }

        let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        c = SIMD3(repeating: luma) + (c - SIMD3(repeating: luma)) * saturation

        // Tints are weighted by the square of the distance from the other end of the
        // range, so each fades out before the midtones and skin stays neutral.
        let shadows = (1 - luma) * (1 - luma), highlights = luma * luma
        c += shadowTint * shadows + highlightTint * highlights

        c = SIMD3(repeating: fade) + c * (1 - fade)
        return c.clamped(lowerBound: .zero, upperBound: .one)
    }

    /// The look as lookup-table data in the layout Core Image expects: RGBA floats, red
    /// varying fastest, then green, then blue.
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

    /// Tables are small but not free to build (36,000 colours), and a gallery applies the
    /// same look to every tile, so each distinct look is built once per process.
    private static let cache = LookCache()

    func filter(on image: CIImage) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize,
            "inputCubeData": Self.cache.data(for: self),
            // The table was built on sRGB-encoded values; Core Image converts from its
            // linear working space and back around the lookup.
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
    /// The picture with a look applied: exposure, then the look's tone curve and style.
    ///
    /// This is the step that makes the two decoders interchangeable. Given scene-linear
    /// data it produces the same kind of picture from either route, because everything
    /// that shapes the picture happens here, after the decoders, and identically for both.
    ///
    /// For that to hold, the image has to *be* scene-linear (`isSceneLinear`). The fallback
    /// always is. Apple's decoder is when opened with `appleRendering = .linear`; opened
    /// with its default rendering it already carries Apple's tone curve, and a look applied
    /// on top of that is a second curve on a finished picture.
    ///
    /// - Parameter exposureEV: stops added to `suggestedExposureEV`.
    public func rendered(look: RawLook = .neutral, exposureEV: Double = 0) -> CIImage {
        var result = image
        let stops = suggestedExposureEV + exposureEV
        if stops != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: stops])
        }
        // The lookup clamps its input to 0...1, which is also what clips the highlights.
        return look.filter(on: result)
    }
}
