import CoreImage
import Foundation

/// Picks a default brightness for a scene-linear image: the exposure that puts the
/// brightest 1% of the frame just under white. It never darkens the picture.
struct ExposureEstimate {
    private var bins = [Int](repeating: 0, count: 1024)
    private var count = 0

    /// Records one channel value, with 1 meaning sensor white. Non-finite values are
    /// ignored, since converting one to an integer would trap.
    mutating func add(_ value: Float) {
        guard value.isFinite else { return }
        bins[Int(min(max(value, 0), 1) * 1023)] += 1
        count += 1
    }

    /// The value below which `fraction` of the samples fall, or 0 with no samples.
    func percentile(_ fraction: Double) -> Float {
        guard count > 0 else { return 0 }
        // One-based.
        let rank = max(1, Int((Double(count) * fraction).rounded(.up)))
        var seen = 0
        for (index, bin) in bins.enumerated() {
            seen += bin
            if seen >= rank { return Float(index) / 1023 }
        }
        return 1
    }

    /// Stops of exposure that lift the 99th percentile to 0.9, limited to between 0 and
    /// +4 EV. The upper limit keeps a black frame from being amplified into noise.
    var suggestedEV: Double {
        let bright = percentile(0.99)
        guard bright > 0 else { return 0 }
        return Double(log2(min(max(0.9 / bright, 1), 16)))
    }

    /// The suggested exposure for a linear image, measured from a render at most 384 pixels
    /// on its long edge, which averages away single hot pixels.
    ///
    /// Both decoders' output is measured here so their default brightness matches. As
    /// per-picture automatic exposure it brightens dark frames and makes a bracketed
    /// series come out alike.
    static func measure(_ image: CIImage) -> Double {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return 0 }
        let scale = min(1, 384 / max(extent.width, extent.height))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let width = max(1, Int(extent.width * scale)), height = max(1, Int(extent.height * scale))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        RenderContext.shared.render(
            small, toBitmap: &pixels, rowBytes: width * 4 * MemoryLayout<Float>.stride,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))

        var estimate = ExposureEstimate()
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            // The brightest channel, so that a saturated colour counts as bright.
            estimate.add(max(pixels[pixel], pixels[pixel + 1], pixels[pixel + 2]))
        }
        return estimate.suggestedEV
    }
}
