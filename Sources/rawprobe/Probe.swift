import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// `rawprobe <folder>`: runs every file through both decoders and records what happened.
/// The output is the evidence for the coverage table in the README.
enum Probe {
    /// One file's result. Field names are the JSON schema `Scripts/coverage.py` and
    /// `Scripts/charts.py` read; rename them there too.
    struct Row: Codable {
        var file: String
        var camera = "?"
        var megapixels = 0.0
        var layout = "?"
        /// LibRaw's decoding routine: in effect, the compression mode.
        var routine = "?"
        /// The year the picture was taken, from its metadata; 0 if unknown.
        var captureYear = 0
        /// Apple's decoder develops the file.
        var apple = false
        /// The fallback develops the file, to actual pixels.
        var fallback = false
        var fallbackDecoder = ""
        var fallbackError = ""
        var fallbackSeconds = 0.0
        /// Colour distance from the embedded preview; see `RawImage.previewDistance`. Nil
        /// when the file has no preview or the route failed.
        var applePreviewDistance: Double?
        var fallbackPreviewDistance: Double?
    }

    /// Probes one file in this process. The folder run calls it through a child process.
    static func measure(_ url: URL) -> Row {
        let context = CIContext()
        let info = try? RawInput.info(url)
        var row = Row(file: url.lastPathComponent)
        if let info {
            row.camera = info.camera
            row.megapixels = info.megapixels
            row.layout = info.layout?.rawValue ?? "?"
            row.routine = info.decoderRoutine ?? "?"
            row.captureYear = info.captureDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) } ?? 0
        }
        row.apple = RawInput.appleCanDecode(url)

        var options = RawDecodeOptions()
        if row.apple {
            options.routing = .apple
            row.applePreviewDistance = (try? RawInput.open(url, options: options)).flatMap {
                RawInput.previewDistance(of: $0.displayImage(), forFileAt: url)
            }
        }

        options.routing = .fallback
        do {
            let start = ContinuousClock.now
            let raw = try RawInput.open(url, options: options)
            let elapsed = (ContinuousClock.now - start).components
            row.fallbackSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
            // Decoding without error is not enough to count: render a centre crop and
            // require that real pixels come out.
            let extent = raw.image.extent
            let crop = extent.insetBy(dx: extent.width * 0.45, dy: extent.height * 0.45)
            row.fallback = RawMeasurement.renderFully(raw.image.cropped(to: crop), context: context)
            row.fallbackDecoder = raw.decoder
            row.fallbackPreviewDistance = raw.previewDistance
        } catch {
            row.fallbackError = error.localizedDescription
        }
        return row
    }

    static func run(folder: URL, jsonPath: String?) throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "part" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let lock = NSLock()
        nonisolated(unsafe) var rows: [Row] = []  // guarded by `lock`
        // Six at a time: each probe is mostly single-threaded and holds a frame or two in
        // memory, so this keeps a laptop responsive while using its cores.
        let slots = DispatchSemaphore(value: 6)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            slots.wait()
            defer { slots.signal() }
            let row = isolated(files[index])
            lock.withLock {
                rows.append(row)
                print(summary(row))
            }
        }

        rows.sort { $0.file < $1.file }
        let both = rows.filter { $0.apple && $0.fallback }.count
        let appleOnly = rows.filter { $0.apple && !$0.fallback }.count
        let fallbackOnly = rows.filter { !$0.apple && $0.fallback }.count
        print("\n\(rows.count) files: both \(both), fallback only \(fallbackOnly), "
            + "Apple only \(appleOnly), neither \(rows.count - both - appleOnly - fallbackOnly)")

        if let jsonPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: jsonPath))
        }
    }

    /// Probes a file where a crash or a hang cannot take the run down with it.
    private static func isolated(_ url: URL) -> Row {
        #if os(macOS)
        var row = Row(file: url.lastPathComponent)
        switch ChildProcess.run(["one", url.path]) as ChildProcess.Outcome<Row> {
        case .value(let measured): return measured
        case .crashed(let status): row.fallbackError = "probe crashed (status \(status))"
        case .timedOut: row.fallbackError = "probe timed out"
        case .notStarted: row.fallbackError = "probe did not start"
        }
        return row
        #else
        // Child processes do not exist off the Mac. The tool is only compiled for other
        // platforms because the package builds as a whole.
        return measure(url)
        #endif
    }

    private static func summary(_ row: Row) -> String {
        func mark(_ ok: Bool) -> String { ok ? "yes" : "NO " }
        func distance(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "  -  " }
        return "apple \(mark(row.apple))  fallback \(mark(row.fallback))  "
            + String(format: "%5.1f MP  %5.2fs  ", row.megapixels, row.fallbackSeconds)
            + "d \(distance(row.applePreviewDistance))/\(distance(row.fallbackPreviewDistance))  "
            + "\(row.camera) [\(row.routine)] \(row.fallbackError)"
    }
}
