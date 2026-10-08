import CoreImage
@_spi(Measurement) import RawInputKit
import simd

/// Compares two renderings of the same picture, on the coarse colour grid the library
/// also uses for its own preview check.
enum ImageGrid {
    /// Mean colour difference between two renderings, in CIELAB ΔE (1976).
    ///
    /// ΔE is the standard unit for "how different do these two colours look": about 1 is
    /// the smallest difference a person can see side by side, 2 to 5 is visible at a glance,
    /// and above 10 the colours are plainly different. Unlike the library's preview check, this counts
    /// brightness and contrast as well as hue, because here the question is whether two
    /// pictures match, not whether a decode is plausible.
    static func deltaE(_ a: CIImage, _ b: CIImage, context: CIContext) -> Double? {
        guard let first = ColorGrid.colors(of: a, context: context),
              let second = ColorGrid.colors(of: b, context: context)
        else {
            return nil
        }
        let total = zip(first, second).reduce(Float(0)) { $0 + simd_distance(lab($1.0), lab($1.1)) }
        let mean = Double(total / Float(first.count))
        return mean.isFinite ? mean : nil
    }

    /// Linear sRGB to CIELAB, D65 white.
    private static func lab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let xyz = SIMD3<Float>(
            0.4124 * c.x + 0.3576 * c.y + 0.1805 * c.z,
            0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z,
            0.0193 * c.x + 0.1192 * c.y + 0.9505 * c.z) / SIMD3(0.9505, 1, 1.089)
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let (fx, fy, fz) = (f(xyz.x), f(xyz.y), f(xyz.z))
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
