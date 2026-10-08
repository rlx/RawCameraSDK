import Foundation

public struct RawDecodeOptions: Sendable {
    /// Which decoder `RawInput.open` may use.
    public enum Routing: Sendable {
        /// Apple's decoder when it can develop the file, the fallback otherwise.
        case automatic
        /// Apple's decoder only; throws `RawError.appleCannotDecode` if it cannot.
        case apple
        /// The fallback only, even for files Apple opens. For comparison and testing.
        case fallback
    }

    public enum AppleRendering: Sendable {
        /// Apple's default look, including its tone curve.
        case standard
        /// Tone boost and gamut mapping switched off, for pipelines that apply their own look.
        case linear
    }

    public enum AppleDecoderVersion: Sendable {
        /// Whatever the OS picks. On OS 27 that is RAW 8.
        case systemDefault
        /// The newest version the OS offers for this file, which is how RAW 9 is opted into.
        case newest
    }

    public var routing: Routing = .automatic

    /// Apple route only.
    public var appleRendering: AppleRendering = .standard

    /// Apple route only.
    public var appleDecoderVersion: AppleDecoderVersion = .systemDefault

    /// Fallback route only: frames with more pixels than this are developed at half the
    /// width and height, by merging each 2x2 cell of the mosaic into one pixel.
    ///
    /// This exists for memory. A developed frame is held as 16-bit float RGBA, 8 bytes per
    /// pixel, so 100 MP needs about 800 MB: more than an iPhone will give a foreground app.
    ///
    /// It is a threshold, not a cap. The frame is halved once, and only mosaic sensors can
    /// be halved; Foveon, monochrome and already-demosaiced files come out at full size
    /// regardless. Check `RawImage.isHalfSize` for what actually happened. The Apple route
    /// ignores it: `CIRAWFilter` renders lazily, in tiles, and manages its own memory.
    public var halfSizeAbovePixels: Int = 64_000_000

    public init() {}
}
