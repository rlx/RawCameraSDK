import CoreImage
import Foundation
import RawInputKit

/// `rawprobe bench`: time and memory from file to a full-resolution rendered image, for
/// each decoder.
///
/// Both decoders hand back a lazy `CIImage`, and Apple's does almost no work until pixels
/// are requested, so "decode time" is only comparable once each image has been rendered.
/// Every measurement runs in its own child process, which keeps one decoder's caches and
/// peak memory out of the other's numbers.
enum Bench {
    struct Sample: Codable {
        /// `RawInput.open` alone.
        var openSeconds: Double
        /// Open plus rendering every pixel.
        var seconds: Double
        var peakMegabytes: Double
        var decoder: String
    }

    struct Row: Codable {
        var file: String
        var camera: String
        var megapixels: Double
        /// "Metal" or "CPU": which fallback path the file takes.
        var path: String
        var appleSeconds: Double
        var appleOpenSeconds: Double
        var applePeakMegabytes: Double
        var fallbackSeconds: Double
        var fallbackOpenSeconds: Double
        var fallbackPeakMegabytes: Double
    }

    /// Child-process entry point: decode, render every pixel, report.
    static func measure(_ url: URL, routing: RawDecodeOptions.Routing) throws -> Sample {
        var options = RawDecodeOptions()
        options.routing = routing
        options.halfSizeAbovePixels = .max  // full resolution on both routes

        let context = CIContext()
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let duration = (clock.now - start).components
            return Double(duration.seconds) + Double(duration.attoseconds) * 1e-18
        }

        let raw = try RawInput.open(url, options: options)
        let openSeconds = elapsed()
        guard FullRender.run(raw.image, context: context) else {
            throw RawError.renderFailed(reason: "the full frame rendered as nothing")
        }
        return Sample(
            openSeconds: openSeconds, seconds: elapsed(), peakMegabytes: peakFootprintMegabytes(),
            decoder: raw.decoder)
    }

    #if os(macOS)
    static func run(files: [URL], jsonPath: String?) throws {
        var rows: [Row] = []
        for url in files {
            guard let info = try? RawInput.info(url) else { continue }
            // Median of three, to shrug off a cold file cache or a busy machine.
            func median(_ route: String) -> Sample? {
                let samples = (0..<3).compactMap { _ in child(url, route: route) }.sorted { $0.seconds < $1.seconds }
                return samples.isEmpty ? nil : samples[samples.count / 2]
            }
            guard let apple = median("apple"), let fallback = median("fallback") else {
                print("skipped \(url.lastPathComponent): one of the decoders failed")
                continue
            }
            let row = Row(
                file: url.lastPathComponent, camera: info.camera, megapixels: info.megapixels,
                path: fallback.decoder.contains("Metal") ? "Metal" : "CPU",
                appleSeconds: apple.seconds, appleOpenSeconds: apple.openSeconds,
                applePeakMegabytes: apple.peakMegabytes, fallbackSeconds: fallback.seconds,
                fallbackOpenSeconds: fallback.openSeconds, fallbackPeakMegabytes: fallback.peakMegabytes)
            rows.append(row)
            print(String(
                format: "%@ (%.0f MP, %@): Apple %.2f s / %.0f MB, fallback %.2f s / %.0f MB",
                row.camera, row.megapixels, row.path, row.appleSeconds, row.applePeakMegabytes,
                row.fallbackSeconds, row.fallbackPeakMegabytes))
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

    /// The process's high-water mark of physical memory, as the OS accounts it for jetsam.
    private static func peakFootprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : 0
    }
}
