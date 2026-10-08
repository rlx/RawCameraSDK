import Foundation
import RawShim

/// A file opened by LibRaw, through the C shim.
///
/// Buffers belong to the LibRaw handle and are exposed only inside a closure, which keeps
/// this object alive. Copy out whatever must outlast the closure.
///
/// Not thread-safe. Separate instances are independent.
final class LibRawFile {
    private let handle: OpaquePointer
    private var cancellation: Cancellation?
    /// The bytes LibRaw reads from when the file was opened from memory. LibRaw does not
    /// copy them, so they are kept here until the handle closes.
    private let bytes: NSData?

    /// Parses the container and metadata. No sensor data is read.
    init(_ source: RawSource) throws {
        var handle: OpaquePointer?
        let code: Int32
        switch source {
        case .file(let url):
            bytes = nil
            code = url.withUnsafeFileSystemRepresentation { rik_open($0, &handle) }
        case .data(let data, _):
            // An NSData's `bytes` pointer is stable for as long as the object lives.
            let held = data as NSData
            bytes = held
            code = rik_open_buffer(held.bytes, held.length, &handle)
        }
        guard code == 0, let handle else { throw Self.error(code) }
        self.handle = handle
    }

    convenience init(_ url: URL) throws { try self.init(.file(url)) }

    deinit { rik_close(handle) }

    /// Geometry, levels and color fields are only meaningful after `unpack()`.
    var info: rik_info {
        var info = rik_info()
        rik_get_info(handle, &info)
        return info
    }

    /// How the sensor data is stored, as text: decoding routine, compression and bit depth.
    var storageMode: String {
        var text = [CChar](repeating: 0, count: 160)
        rik_storage_mode(handle, &text, text.count)
        return String(decoding: text.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// Has `withDeveloped` convert to Rec. 2020 primaries, which keep colors that sRGB
    /// primaries clip. Call before `withDeveloped`.
    func useWideGamutOutput() {
        rik_set_output_primaries(handle, RIK_PRIMARIES_REC2020)
    }

    /// Refuses files whose sensor data would need more than this to decode. Call before `unpack`.
    func setMemoryLimit(megabytes: Int) {
        rik_set_memory_limit(handle, UInt32(clamping: megabytes))
    }

    /// Has the decoder poll `isCancelled` between stages of `unpack` and `withDeveloped`.
    func setCancellation(_ isCancelled: @escaping @Sendable () -> Bool) {
        let box = Cancellation(isCancelled)
        cancellation = box  // owned here, so the pointer below stays valid until deinit
        rik_set_cancel_callback(handle, { context in
            Unmanaged<Cancellation>.fromOpaque(context!).takeUnretainedValue().isCancelled() ? 1 : 0
        }, Unmanaged.passUnretained(box).toOpaque())
    }

    /// Decompresses the sensor data. Takes tens of milliseconds to several seconds.
    func unpack() throws {
        let code = rik_unpack(handle)
        guard code == 0 else { throw Self.error(code) }
    }

    /// The GPU kernel's inputs, or `nil` if the file is not a plain Bayer mosaic.
    var developParameters: rik_develop_params? {
        var parameters = rik_develop_params()
        return rik_get_develop_params(handle, &parameters) == 0 ? parameters : nil
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

    /// LibRaw's CPU development: linear 16-bit RGB or gray, unrotated. sRGB primaries unless
    /// `useWideGamutOutput` was called.
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
        switch code {
        case RIK_CANCELLED: .cancelled
        case RIK_TOO_BIG: .exceedsMemoryLimit
        default: .fallbackCannotDecode(code: code, reason: String(cString: rik_strerror(code)))
        }
    }
}

/// Boxes the cancellation closure for use as a C context pointer.
private final class Cancellation {
    let isCancelled: @Sendable () -> Bool
    init(_ isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
}
