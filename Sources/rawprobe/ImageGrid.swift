import CoreImage
@_spi(Measurement) import RawInputKit
import simd

/// Compares two renderings of the same picture on the library's coarse colour grid.
enum ImageGrid {
    /// Mean colour difference between two renderings, in CIELAB ΔE (1976).
    /// About 1 is just visible side by side, and above 10 is plainly different.
    /// Counts brightness and contrast as well as hue.
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
