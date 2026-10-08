import Foundation

public enum RawError: Error, Equatable, Sendable {
    /// The file does not exist or cannot be read. For a file from a document picker, check
    /// that its security-scoped access is still active.
    case fileUnreadable(URL)
    /// Apple's RAW engine cannot develop this file on this OS.
    case appleCannotDecode
    /// The fallback decoder rejected the file. `code` is the decoder's own status, kept for
    /// logs and bug reports; `reason` is its description.
    case fallbackCannotDecode(code: Int32, reason: String)
    /// The sensor data is truncated or corrupt. The fallback can produce an image from such
    /// a file, but part of it is garbage, so it is reported as a failure.
    case corruptData
    /// Decoding the file would need more memory than `RawDecodeOptions.fallbackMemoryLimitMB`.
    case exceedsMemoryLimit
    /// `RawDecodeOptions.isCancelled` returned true while the file was being decoded.
    case cancelled
    /// Rendering failed after a successful decode. `reason` carries the underlying error.
    case renderFailed(reason: String)
    /// The file has no embedded preview and cannot be developed to make one.
    case noPreview
}

extension RawError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileUnreadable(let url): "\(url.lastPathComponent) cannot be read."
        case .appleCannotDecode: "Apple's RAW decoder cannot open this file."
        case .fallbackCannotDecode(let code, let reason): "The fallback decoder cannot open this file: \(reason) (\(code))."
        case .corruptData: "The file's image data is truncated or corrupt."
        case .exceedsMemoryLimit: "The file needs more memory to decode than the limit allows."
        case .cancelled: "Decoding was cancelled."
        case .renderFailed(let reason): "Rendering failed: \(reason)."
        case .noPreview: "The file has no embedded preview."
        }
    }
}
