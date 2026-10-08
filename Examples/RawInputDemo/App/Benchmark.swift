import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// Headless measurement mode, for timing the decoders on a real device.
///
///     RawInputDemo -benchmarkFile samsung-nx1.srw -benchmarkRoute fallback
///
/// The app decodes that one file, renders every pixel, prints one line of JSON prefixed
/// with `RAWBENCH` and exits. `Scripts/device-bench.py` launches it once per file and
/// route through `devicectl` and collects the lines.
///
/// One measurement per launch is deliberate. Peak memory is a lifetime high-water mark
/// that cannot be reset, and iOS terminates an app that uses too much; a fresh process per
/// run gives each decode its own number and turns a termination into a missing line for
/// that file instead of a lost session.
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
        /// Embedded preview, 600 px: what a gallery pays per tile.
        var previewSeconds = 0.0
        /// `RawInput.open` alone.
        var openSeconds = 0.0
        /// Open plus rendering the whole frame to 8-bit sRGB: what an export pays.
        var totalSeconds = 0.0
        /// The same again, a second time in the same process. The first decode in a process
        /// also pays for one-off setup, such as shader compilation and whatever Apple's
        /// engine prepares per camera; this is what every later file costs.
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
        // "apple" measures Apple's decoder alone, without this library's support check in
        // front of it; "automatic" is what an app calling `RawInput.open` would pay.
        func open() throws -> RawImage {
            try route == "apple"
                ? RawInput.openAppleUnchecked(url, options: options)
                : RawInput.open(url, options: options)
        }
        // Everything else is left at its default, half-size threshold included: this
        // measures what the library does on the device, not what it could be pushed to.
        start = clock.now
        do {
            let raw = try open()
            result.openSeconds = seconds(since: start)
            result.decoder = raw.decoder
            result.width = Int(raw.image.extent.width)
            result.height = Int(raw.image.extent.height)
            result.isHalfSize = raw.isHalfSize
            let rendered = FullRender.run(raw.image, context: CIContext())
            result.totalSeconds = seconds(since: start)
            if !rendered { result.error = "nothing was rendered" }
            // Read now, before the second pass: the high-water mark cannot be reset, and
            // two decodes in one process would report the pair's peak, not one decode's.
            result.peakMegabytes = peakFootprintMegabytes()

            start = clock.now
            let again = try open()
            _ = FullRender.run(again.image, context: CIContext())
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

    private static func peakFootprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : 0
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
