import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// `rawprobe bench`: time and memory from file to a fully rendered image, per decoder.
///
/// Both decoders return a lazy `CIImage`, so times are compared after rendering.
/// Each measurement runs in its own child process.
///
///   - `apple`: Apple's decoder alone, default rendering, no support check.
///   - `apple-linear`: Apple's decoder with scene-linear output. Includes the second,
///     reduced decode that measures exposure.
///   - `automatic`: `RawInput.open` in a fresh process, support check included.
///   - `fallback`: the fallback, forced.
enum Bench {
    struct Sample: Codable {
        /// `RawInput.open` alone.
        var openSeconds: Double
        /// Open plus rendering every pixel.
        var seconds: Double
        var peakMegabytes: Double
        var path: RawFallbackPath?
    }

    struct Row: Codable {
        var file: String
        var camera: String
        var megapixels: Double
        /// Fallback path: "Metal" or "CPU".
        var path: String
        var appleSeconds: Double
        var applePeakMegabytes: Double
        var appleLinearSeconds: Double
        var automaticSeconds: Double
        var fallbackSeconds: Double
        var fallbackPeakMegabytes: Double
    }

    /// Child-process entry point.
    /// - Parameter route: "apple", "apple-linear", "automatic" or "fallback".
    static func measure(_ url: URL, route: String) throws -> Sample {
        var options = RawDecodeOptions()
        options.routing = route == "fallback" ? .fallback : .automatic
        options.appleRendering = route == "apple-linear" ? .linear : .standard
        options.fallbackMemoryLimitMB = .max  // measure the full frame
        options.halfSizeAbovePixels = .max  // full resolution on both routes

        let context = CIContext()
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let duration = (clock.now - start).components
            return Double(duration.seconds) + Double(duration.attoseconds) * 1e-18
        }

        let raw = try route.hasPrefix("apple")
            ? RawInput.openAppleUnchecked(url, options: options)
            : RawInput.open(url, options: options)
        let openSeconds = elapsed()
        guard RawMeasurement.renderFully(raw.image, context: context) else {
            throw RawError.renderFailed(reason: "the full frame rendered as nothing")
        }
        return Sample(
            openSeconds: openSeconds, seconds: elapsed(), peakMegabytes: RawMeasurement.memoryFootprint.peakMB,
            path: raw.fallbackPath)
    }

    #if os(macOS)
    static func run(files: [URL], jsonPath: String?) throws {
        var rows: [Row] = []
        for url in files {
            guard let info = try? RawInput.info(url) else { continue }
            // Median of three.
            func median(_ route: String) -> Sample? {
                let samples = (0..<3).compactMap { _ in child(url, route: route) }.sorted { $0.seconds < $1.seconds }
                return samples.isEmpty ? nil : samples[samples.count / 2]
            }
            guard let apple = median("apple"), let appleLinear = median("apple-linear"),
                  let automatic = median("automatic"), let fallback = median("fallback")
            else {
                print("skipped \(url.lastPathComponent): one of the decoders failed")
                continue
            }
            let row = Row(
                file: url.lastPathComponent, camera: info.camera, megapixels: info.megapixels,
                path: fallback.path == .gpu ? "Metal" : "CPU",
                appleSeconds: apple.seconds, applePeakMegabytes: apple.peakMegabytes,
                appleLinearSeconds: appleLinear.seconds,
                automaticSeconds: automatic.seconds, fallbackSeconds: fallback.seconds,
                fallbackPeakMegabytes: fallback.peakMegabytes)
            rows.append(row)
            print(String(
                format: "%@ (%.0f MP, %@): Apple %.2f s / %.0f MB (linear %.2f s, automatic %.2f s), fallback %.2f s / %.0f MB",
                row.camera, row.megapixels, row.path, row.appleSeconds, row.applePeakMegabytes,
                row.appleLinearSeconds, row.automaticSeconds, row.fallbackSeconds, row.fallbackPeakMegabytes))
        }
        if let jsonPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: jsonPath))
        }
    }

    private static func child(_ url: URL, route: String) -> Sample? {
        guard case .value(let sample) = ChildProcess.run(["bench-one", route, url.path]) as ChildProcess.Outcome<Sample>
        else { return nil }
        return sample
    }
    #endif
}
