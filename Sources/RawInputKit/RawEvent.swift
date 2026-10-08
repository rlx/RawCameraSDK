import Foundation

/// An event from opening a file, for logs or analytics.
///
/// Delivered synchronously on the decoding thread through `RawDecodeOptions.eventHandler`.
public enum RawEvent: Sendable, Equatable {
    /// Apple's decoder could not develop the file, so the fallback is being used.
    /// `routine` is the fallback's name for the file's compression scheme.
    case appleRejected(camera: String, routine: String?)
    /// The GPU path failed and the CPU path took over.
    case gpuDevelopFailed(camera: String, reason: String)
    /// The fallback's colours disagree with the camera's embedded preview.
    case colorSuspect(camera: String, distance: Double)
    /// A file was opened. `seconds` is the time spent inside `RawInput.open`. On the Apple
    /// route that excludes the decode, which happens at render time.
    case opened(camera: String, route: RawRoute, decoder: String, seconds: Double)
}
