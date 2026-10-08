import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// `rawprobe fuzz`: feeds the fallback damaged copies of real files and records crashes
/// and hangs.
///
/// Each damaged file is decoded in a child process, and a failing case is kept for
/// replay. Damage is a few overwritten bytes, mostly in the first 64 KB, and sometimes a
/// truncation. It is seeded, so a run can be repeated. Exits with status 1 if anything
/// crashed or hung.
enum Fuzz {
    /// Child-process entry point: every public operation the fallback offers, on one file.
    static func exercise(_ url: URL) {
        _ = try? RawInput.info(url)
        _ = try? RawInput.preview(url, maxPixelSize: 256)
        var options = RawDecodeOptions()
        options.routing = .fallback
        if let raw = try? RawInput.open(url, options: options) {
            _ = RawMeasurement.renderFully(raw.rendered(look: .film), context: CIContext())
        }
        // The same bytes from memory, which LibRaw reads through a different data stream.
        if let data = try? Data(contentsOf: url) {
            _ = try? RawInput.info(data: data)
            _ = try? RawInput.open(data: data, options: options)
        }
    }

    #if os(macOS)
    static func run(seeds: [URL], iterations: Int, seed: UInt64, keepIn folder: URL) throws {
        var random = SplitMix64(state: seed)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "rawprobe-fuzz-\(seed)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let originals = try seeds.map { (url: $0, data: try Data(contentsOf: $0)) }
        var crashes = 0, hangs = 0
        for iteration in 0..<iterations {
            let original = originals[iteration % originals.count]
            let damaged = damage(original.data, using: &random)
            let file = scratch.appending(path: "case-\(iteration).\(original.url.pathExtension)")
            try damaged.write(to: file)

            switch ChildProcess.run(["fuzz-one", file.path], timeout: 60) as ChildProcess.Outcome<Bool> {
            case .value:
                try? FileManager.default.removeItem(at: file)
            case .crashed(let status):
                crashes += 1
                try keep(file, in: folder)
                print("crash (status \(status)) from \(original.url.lastPathComponent): kept \(file.lastPathComponent)")
            case .timedOut:
                hangs += 1
                try keep(file, in: folder)
                print("hang from \(original.url.lastPathComponent): kept \(file.lastPathComponent)")
            case .notStarted:
                print("could not start a child process")
                return
            }
        }
        print("\(iterations) damaged files from \(seeds.count) originals, seed \(seed): "
            + "\(crashes) crashes, \(hangs) hangs")
        // A finding fails the command, so CI can run it.
        if crashes + hangs > 0 { exit(1) }
    }

    private static func keep(_ file: URL, in folder: URL) throws {
        let destination = folder.appending(path: file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private static func damage(_ data: Data, using random: inout SplitMix64) -> Data {
        var bytes = data
        guard !bytes.isEmpty else { return bytes }
        // One case in eight is truncated.
        if random.next() % 8 == 0 {
            bytes = bytes.prefix(Int(random.next() % UInt64(bytes.count)))
        }
        guard !bytes.isEmpty else { return bytes }
        let header = min(bytes.count, 65_536)
        for _ in 0..<(1 + Int(random.next() % 8)) {
            // Three in four land in the header.
            let range = random.next() % 4 == 0 ? bytes.count : header
            let offset = Int(random.next() % UInt64(range))
            // Extreme values stress integer handling.
            let interesting: [UInt8] = [0x00, 0xFF, 0x7F, 0x80, 0x01]
            bytes[bytes.startIndex + offset] = random.next() % 2 == 0
                ? interesting[Int(random.next() % UInt64(interesting.count))]
                : UInt8(truncatingIfNeeded: random.next())
        }
        return bytes
    }
    #endif
}

/// Seedable generator. The same seed always produces the same damage.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
