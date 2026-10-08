import Foundation
import RawShim

/// A file opened by LibRaw, through the C shim.
///
/// The shim hands out pointers into buffers the LibRaw handle owns. Swift is free to
/// destroy an object after its last *use*, which can be earlier than the end of its scope,
/// so "the buffer lives as long as this object" is not a contract a caller can lean on.
/// Buffers are therefore only ever exposed inside a closure, during which this object is
/// pinned alive. Copy out whatever must outlast the closure.
///
/// Not thread-safe: use an instance from one thread. Separate instances are independent.
final class LibRawFile {
    private let handle: OpaquePointer

    /// Parses the container and metadata. Cheap; no sensor data is read.
    init(_ url: URL) throws {
        var handle: OpaquePointer?
        let code = url.withUnsafeFileSystemRepresentation { rik_open($0, &handle) }
        guard code == 0, let handle else { throw Self.error(code) }
        self.handle = handle
    }

    deinit { rik_close(handle) }

    /// A snapshot of the shim's view of the file. Geometry, levels and colour fields are
    /// only meaningful after `unpack()`.
    var info: rik_info {
        var info = rik_info()
        rik_get_info(handle, &info)
        return info
    }

    /// Decompresses the sensor data: the expensive step, from tens of milliseconds to
    /// several seconds depending on the format.
    func unpack() throws {
        let code = rik_unpack(handle)
        guard code == 0 else { throw Self.error(code) }
    }

    /// The raw Bayer plane, or `nil` if the file is not one the GPU kernel can develop.
    func withMosaic<Result>(
        _ body: (_ samples: UnsafePointer<UInt16>, _ rowBytes: Int) throws -> Result
    ) rethrows -> Result? {
        try withExtendedLifetime(self) {
            var rowBytes = 0
            guard let samples = rik_mosaic(handle, &rowBytes) else { return nil }
            return try body(samples, rowBytes)
        }
    }

    /// LibRaw's CPU development of the file: linear 16-bit RGB or grey, not rotated.
    func withDeveloped<Result>(halfSize: Bool, _ body: (rik_rgb16) throws -> Result) throws -> Result {
        try withExtendedLifetime(self) {
            var image = rik_rgb16()
            let code = rik_process_rgb16(handle, halfSize ? 1 : 0, &image)
            guard code == 0 else { throw Self.error(code) }
            return try body(image)
        }
    }

    /// The largest embedded preview.
    func withThumbnail<Result>(_ body: (rik_thumbnail) throws -> Result) throws -> Result {
        try withExtendedLifetime(self) {
            var thumbnail = rik_thumbnail()
            let code = rik_get_thumbnail(handle, &thumbnail)
            guard code == 0 else { throw Self.error(code) }
            return try body(thumbnail)
        }
    }

    private static func error(_ code: Int32) -> RawError {
        .libRaw(code: code, message: String(cString: rik_strerror(code)))
    }
}
