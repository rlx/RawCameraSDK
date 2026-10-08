import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// Headless measurement mode, for timing the decoders on a device.
///
///     RawInputDemo -benchmarkFile samsung-nx1.srw -benchmarkRoute fallback
///
/// Decodes the file, renders every pixel, prints one line of JSON prefixed with
/// `RAWBENCH` and exits. `Scripts/device-bench.py` launches it once per file and route.
/// One measurement per launch, because peak memory cannot be reset and iOS terminates
/// an app that uses too much.
enum Benchmark {
    struct Result: Codable {
        var file: String
        var route: String
        var camera = ""
        var megapixels = 0.0
        var decoder = ""
        var width = 0
        var height = 0
        var isHalfSize = false
        /// Embedded preview, 600 px.
        var previewSeconds = 0.0
        /// `RawInput.open` alone.
        var openSeconds = 0.0
        /// Open plus rendering the whole frame to 8-bit sRGB.
        var totalSeconds = 0.0
        /// The same again in the same process, without one-off setup such as shader compilation.
        var secondTotalSeconds = 0.0
        var peakMegabytes = 0.0
        var error = ""
        var device = ""
        var system = ""
    }

    /// Runs and exits if the launch arguments ask for a benchmark; returns otherwise.
    static func runIfRequested() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "benchmarkFile") else { return }
        let route = defaults.string(forKey: "benchmarkRoute") ?? "automatic"

        var result = Result(file: name, route: route)
        result.device = hardwareModel()
        result.system = ProcessInfo.processInfo.operatingSystemVersionString

        if let url = locate(name) {
            measure(url, route: route, into: &result)
        } else {
            result.error = "file not found in the app bundle or Documents"
        }

        let line = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("RAWBENCH \(line)")
        fflush(stdout)
        exit(0)
    }

    private static func measure(_ url: URL, route: String, into result: inout Result) {
        let clock = ContinuousClock()
        func seconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = (clock.now - start).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        }

        if let info = try? RawInput.info(url) {
            result.camera = info.camera
            result.megapixels = info.megapixels
        }

        var start = clock.now
        _ = try? RawInput.preview(url, maxPixelSize: 600)
        result.previewSeconds = seconds(since: start)

        var options = RawDecodeOptions()
        options.routing = route == "fallback" ? .fallback : .automatic
        options.appleRendering = route == "apple-linear" ? .linear : .standard
        // "apple" and "apple-linear" skip this library's support check. "automatic" is
        // `RawInput.open` as an app calls it.
        func open() throws -> RawImage {
            try route.hasPrefix("apple")
                ? RawInput.openAppleUnchecked(url, options: options)
                : RawInput.open(url, options: options)
        }
        // Everything else stays at its default, half-size threshold included.
        start = clock.now
        do {
            let raw = try open()
            result.openSeconds = seconds(since: start)
            result.decoder = raw.decoder
            result.width = Int(raw.image.extent.width)
            result.height = Int(raw.image.extent.height)
            result.isHalfSize = raw.isHalfSize
            let rendered = RawMeasurement.renderFully(raw.image, context: CIContext())
            result.totalSeconds = seconds(since: start)
            if !rendered { result.error = "nothing was rendered" }
            // Read before the second pass. The high-water mark cannot be reset.
            result.peakMegabytes = RawMeasurement.memoryFootprint.peakMB

            start = clock.now
            let again = try open()
            _ = RawMeasurement.renderFully(again.image, context: CIContext())
            result.secondTotalSeconds = seconds(since: start)
        } catch {
            result.error = error.localizedDescription
        }
    }

    /// Bundled samples first, then files copied into the app's Documents folder.
    private static func locate(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "files/\(name)"),
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appending(path: name),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The hardware identifier, e.g. "iPhone17,2".
    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(decoding: machine.prefix { $0 != 0 }, as: UTF8.self)
    }
}
