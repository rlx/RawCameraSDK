import CoreImage
import Foundation
import RawInputKit

/// `rawprobe match`: how alike the two decoders' pictures are on files both can open.
///
///   - each decoder's default output. Large, mostly because only Apple's has a tone curve.
///   - both scene-linear at measured exposure, no look. How alike the decoders' data is.
///   - both through the same `RawLook`.
enum Match {
    /// Field names are read by `Scripts/charts.py`.
    struct Row: Codable {
        var file: String
        var camera: String
        /// ΔE between the routes at each stage.
        var ownOutput: Double
        var linear: Double
        var sharedNeutral: Double
        var sharedFilm: Double
    }

    static func measure(_ url: URL) throws -> Row {
        let context = CIContext()
        let appleOwn = try Compare.open(url, .apple)
        let appleLinear = try Compare.open(url, .apple, linear: true)
        let fallback = try Compare.open(url, .fallback)
        func difference(_ a: CIImage, _ b: CIImage) throws -> Double {
            guard let value = ImageGrid.deltaE(a, b, context: context) else {
                throw RawError.renderFailed(reason: "could not compare the renderings")
            }
            return value
        }
        return Row(
            file: url.lastPathComponent, camera: fallback.info.camera,
            ownOutput: try difference(appleOwn.displayImage(), fallback.displayImage()),
            linear: try difference(appleLinear.displayImage(), fallback.displayImage()),
            sharedNeutral: try difference(appleLinear.rendered(look: .neutral), fallback.rendered(look: .neutral)),
            sharedFilm: try difference(appleLinear.rendered(look: .film), fallback.rendered(look: .film)))
    }

    static func run(files: [URL], jsonPath: String?) throws {
        let lock = NSLock()
        nonisolated(unsafe) var rows: [Row] = []  // guarded by `lock`
        let slots = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            slots.wait()
            defer { slots.signal() }
            // Skips files one decoder cannot open.
            guard let row = try? autoreleasepool(invoking: { try measure(files[index]) }) else { return }
            lock.withLock {
                rows.append(row)
                print(String(
                    format: "own %5.1f   linear %5.1f   neutral %5.1f   film %5.1f   %@", row.ownOutput,
                    row.linear, row.sharedNeutral, row.sharedFilm, row.camera))
            }
        }
        rows.sort { $0.file < $1.file }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        guard !rows.isEmpty else { return print("no file was opened by both decoders") }
        print(String(
            format: "\n%d files, median ΔE: own output %.1f, linear %.1f, shared neutral %.1f, shared film %.1f",
            rows.count, median(rows.map(\.ownOutput)), median(rows.map(\.linear)),
            median(rows.map(\.sharedNeutral)), median(rows.map(\.sharedFilm))))
        if let jsonPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: jsonPath))
        }
    }
}
