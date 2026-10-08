import Foundation

public struct RawDecodeOptions: Sendable {
    /// Which decoder `RawInput.open` may use.
    public enum Routing: Sendable {
        /// Apple's decoder when it can develop the file, the fallback otherwise.
        case automatic
        /// Apple's decoder only. Throws `RawError.appleCannotDecode` if it cannot develop the file.
        case apple
        /// The fallback only, even for files Apple opens.
        case fallback
    }

    public enum AppleRendering: Sendable {
        /// Apple's default look, including its tone curve.
        case standard
        /// Tone boost and gamut mapping switched off.
        case linear
    }

    public enum AppleDecoderVersion: Sendable {
        /// Whatever the OS picks. On OS 27 that is RAW 8.
        case systemDefault
        /// The newest version the OS offers for this file. Opts into RAW 9.
        case newest
    }

    public var routing: Routing = .automatic

    /// Apple route only.
    public var appleRendering: AppleRendering = .standard

    /// Apple route only.
    public var appleDecoderVersion: AppleDecoderVersion = .systemDefault

    /// Fallback route only: frames with more pixels than this are developed at half the
    /// width and height. A developed frame takes 8 bytes per pixel.
    ///
    /// The frame is halved once, and only mosaic sensors can be halved. Check
    /// `RawImage.isHalfSize` for the outcome.
    public var halfSizeAbovePixels: Int = 64_000_000

    /// Fallback route only: the most memory, in megabytes, the decoder may allocate for one
    /// file. A file whose header asks for more throws `RawError.exceedsMemoryLimit`.
    public var fallbackMemoryLimitMB = 1024

    /// Fallback route only: polled between decoding stages on the decoding thread. Return
    /// true to abandon the decode, which then throws `RawError.cancelled`.
    public var isCancelled: (@Sendable () -> Bool)?

    /// Receives `RawEvent`s as the file is opened. Called on the decoding thread.
    public var eventHandler: (@Sendable (RawEvent) -> Void)?

    /// Fallback route only: compare the developed image with the camera's embedded preview
    /// and report the result in `RawImage.previewDistance`. Costs one small JPEG decode and
    /// two tiny renders.
    public var checksColorAgainstPreview = true

    public init() {}

    /// Options that give scene-linear data from both routes.
    public static var sceneLinear: RawDecodeOptions {
        var options = RawDecodeOptions()
        options.appleRendering = .linear
        return options
    }
}
