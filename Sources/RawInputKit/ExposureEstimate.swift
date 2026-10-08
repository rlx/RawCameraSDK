import CoreImage
import Foundation

/// Picks a default brightness for a scene-linear image.
///
/// Sensor data normalised to its white level looks dark: cameras expose to protect
/// highlights and rely on a tone curve to lift the rest. The fallback applies no tone
/// curve, so it reports the exposure that would put the brightest 1% of the frame just
/// under white and leaves applying it to the caller. That is the rule dcraw-derived viewers
/// use for their default brightness, and it is predictable: it never clips more than 1% of
/// the picture and never darkens it.
struct ExposureEstimate {
    private var bins = [Int](repeating: 0, count: 1024)
    private var count = 0

    /// Records one sample: any channel value, with 1 meaning sensor white. Values that are
    /// not finite are ignored; they can only come from a malformed file, and converting one
    /// to an integer would trap.
    mutating func add(_ value: Float) {
        guard value.isFinite else { return }
        bins[Int(min(max(value, 0), 1) * 1023)] += 1
        count += 1
    }

    /// The value below which `fraction` of the samples fall; 0 with no samples.
    func percentile(_ fraction: Double) -> Float {
        guard count > 0 else { return 0 }
        // The rank of the sample that sits at `fraction`, counting from one.
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

    /// The suggested exposure for a linear image, measured from a small render of it.
    ///
    /// Both decoders' output goes through this one function, and that is the point. The
    /// shared rendering step can only make two decoders' pictures match if their default
    /// brightness is decided the same way, from the same kind of evidence. Measuring each
    /// decoder's data with its own method (sensor samples for one, rendered pixels for the
    /// other) left the two visibly further apart.
    ///
    /// The image is reduced to at most 384 pixels on its long edge first. That is plenty for
    /// a percentile and averages away single hot pixels that would otherwise set the
    /// white point.
    ///
    /// This is automatic exposure per picture, and it has the usual drawback: it removes
    /// the photographer's intent from a dark frame, and it makes the frames of
    /// a bracketed series come out alike. It is a default for viewing, exposed as
    /// `suggestedExposureEV` so a caller can ignore it. A product would use a calibrated
    /// baseline per camera and leave the picture's own exposure alone.
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
