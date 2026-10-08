import CoreImage
import simd

/// An image averaged down to a coarse grid of colors, for comparing two renderings of the
/// same picture. Not part of the supported API.
@_spi(Measurement)
public enum ColorGrid {
    public static let columns = 24, rows = 16

    /// Linear sRGB colors, row by row from the top, or `nil` for an empty or infinite image.
    /// The image is stretched to the grid whatever its aspect ratio.
    public static func colors(of image: CIImage, context: CIContext) -> [SIMD3<Float>]? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let scale = CGFloat(rows) / extent.height
        // Lanczos averages over the source area. An affine downscale would sample single pixels.
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: (CGFloat(columns) / extent.width) / scale,
            ])
        var pixels = [Float](repeating: 0, count: columns * rows * 4)
        context.render(
            scaled, toBitmap: &pixels, rowBytes: columns * 4 * MemoryLayout<Float>.stride,
            bounds: CGRect(x: 0, y: 0, width: columns, height: rows), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        return (0..<(columns * rows)).map { SIMD3(pixels[$0 * 4], pixels[$0 * 4 + 1], pixels[$0 * 4 + 2]) }
    }
}

/// Checks a developed image against the camera's embedded preview.
///
/// Only chromaticity is compared, because the preview has a tone curve. The result is the
/// mean distance over the grid: below 0.05 is usual for a correct decode, above 0.15 is
/// suspect. A vivid picture style raises it. Across 944 test files about one correct
/// decode in a hundred lands above the threshold.
enum PreviewAgreement {
    static func distance(_ image: CIImage, preview: CGImage, context: CIContext = RenderContext.shared) -> Double? {
        guard let developed = ColorGrid.colors(of: image, context: context),
              let reference = ColorGrid.colors(of: CIImage(cgImage: preview), context: context)
        else { return nil }
        var total: Float = 0
        for (a, b) in zip(developed, reference) {
            total += simd_length(chromaticity(a) - chromaticity(b))
        }
        let distance = Double(total / Float(developed.count))
        return distance.isFinite ? distance : nil
    }

    /// Red and green as fractions of the total. The constant damps near-black cells.
    private static func chromaticity(_ color: SIMD3<Float>) -> SIMD2<Float> {
        let clamped = simd_max(color, SIMD3(repeating: 0))
        return SIMD2(clamped.x, clamped.y) / (clamped.sum() + 0.02)
    }
}
