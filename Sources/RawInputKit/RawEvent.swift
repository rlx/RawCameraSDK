import Foundation

/// Something worth recording that happened while a file was opened.
///
/// A decoder that quietly falls back, or quietly returns a picture it has doubts about, is
/// invisible in production. These are the moments an app would want in its logs or
/// analytics: they answer "how often does Apple's decoder turn a file away, and for which
/// cameras?", which is the question to settle before investing in a fallback at all.
///
/// Events are delivered synchronously on the thread doing the decoding, through
/// `RawDecodeOptions.eventHandler`. Keep the handler quick.
public enum RawEvent: Sendable, Equatable {
    /// Apple's decoder could not develop the file, so the fallback is being used.
    /// `routine` is the fallback's name for the file's compression scheme.
    case appleRejected(camera: String, routine: String?)
    /// The GPU path failed and the CPU path took over. The file still decodes; it is slower.
    case gpuDevelopFailed(camera: String, reason: String)
    /// The fallback's colours disagree with the camera's embedded preview.
    case colorSuspect(camera: String, distance: Double)
    /// A file was opened. `seconds` is the time spent inside `RawInput.open`, which on the
    /// Apple route excludes the decode itself, since that happens at render time.
    case opened(camera: String, route: RawRoute, decoder: String, seconds: Double)
}
