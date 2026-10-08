import CoreImage
import simd

/// A measure of whether a developed image has the right colours, using the only reference
/// every RAW file carries: the preview its own camera rendered.
///
/// "The decoder returned pixels" says nothing about whether they are right. A wrong black
/// level, white balance, colour matrix, crop or rotation all still produce a picture. This
/// compares the developed image with the embedded preview on a coarse grid and reports how
/// far apart their colours are.
///
/// Only chromaticity is compared (the proportions of red, green and blue), not brightness,
/// because the camera's preview has a tone curve and a picture style that a neutral decode
/// lacks by design. The value is the mean distance over the grid:
///
///     below 0.05   the usual range for a correct decode
///     above 0.15   suspect: worth looking at the picture
///
/// It is a screening tool, not a colour-accuracy metric. A vivid picture style in the
/// camera raises it for a perfectly good decode.
enum PreviewDistance {
    private static let columns = 24, rows = 16

    static func measure(_ image: CIImage, preview: CGImage, context: CIContext) -> Double? {
        guard let developed = grid(image, context: context),
              let reference = grid(CIImage(cgImage: preview), context: context)
        else { return nil }
        var total: Float = 0
        for (a, b) in zip(developed, reference) {
            total += simd_length(chromaticity(a) - chromaticity(b))
        }
        let distance = Double(total / Float(developed.count))
        return distance.isFinite ? distance : nil
    }

    /// The image averaged down to a small grid of linear sRGB colours.
    ///
    /// Each image is stretched to the same grid whatever its aspect ratio, so a decode with
    /// the wrong crop or rotation lands different content in each cell and scores badly,
    /// which is the intent.
    private static func grid(_ image: CIImage, context: CIContext) -> [SIMD3<Float>]? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let scale = CGFloat(rows) / extent.height
        // Lanczos averages over the source area; a plain affine downscale by this much
        // would sample single pixels and turn noise into colour error.
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

    /// Red and green as fractions of the total. The small constant keeps near-black cells,
    /// where the ratio is mostly noise, from dominating.
    private static func chromaticity(_ color: SIMD3<Float>) -> SIMD2<Float> {
        let clamped = simd_max(color, SIMD3(repeating: 0))
        return SIMD2(clamped.x, clamped.y) / (clamped.sum() + 0.02)
    }
}
