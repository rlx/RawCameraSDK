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
}
