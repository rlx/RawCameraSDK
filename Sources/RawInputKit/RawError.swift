import Foundation

public enum RawError: Error, Equatable, Sendable {
    /// The file does not exist or cannot be read. For a file from a document picker, check
    /// that its security-scoped access is still active.
    case fileUnreadable(URL)
    /// Apple's RAW engine cannot develop this file on this OS.
    case appleCannotDecode
    /// LibRaw rejected the file. `code` is a `LibRaw_errors` value; -2 (unsupported format)
    /// and -4 (not implemented for this camera) are the common ones.
    case libRaw(code: Int32, message: String)
    /// The sensor data is truncated or corrupt. LibRaw can produce an image from such a
    /// file, but part of it is garbage, so it is reported as a failure.
    case corruptData
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
        case .libRaw(let code, let message): "LibRaw: \(message) (\(code))."
        case .corruptData: "The file's image data is truncated or corrupt."
        case .renderFailed(let reason): "Rendering failed: \(reason)."
        case .noPreview: "The file has no embedded preview."
        }
    }
}
