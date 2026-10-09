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

    public enum AppleDecoderVersion: Sendable, Equatable {
        /// Whatever the OS picks. On OS 27 that is RAW 8.
        case systemDefault
        /// The newest version the OS offers for this file. Opts into RAW 9.
        case newest
        /// The version an earlier decode reported in `RawImage.appleDecoderVersion`. Store
        /// that value with an edit and pass it here to reopen the edit with the same
        /// rendering after an OS update. Throws
        /// `RawError.appleDecoderVersionUnavailable` if the OS no longer offers it.
        case pinned(String)
    }

    /// How `.automatic` routing decides that Apple's decoder can develop a file.
    public enum AppleSupportCheck: Sendable {
        /// Test the first file of each camera and storage mode, then trust the answer for
        /// the life of the process. A damaged file from a supported camera goes to Apple
        /// untested and can render empty.
        case oncePerKind
        /// Test every file. Costs a partial decode per file, 0.1 to 0.7 s on a Mac.
        case everyFile
    }

    public var routing: Routing = .automatic

    /// Apple route only.
    public var appleRendering: AppleRendering = .standard

    /// Apple route only.
    public var appleDecoderVersion: AppleDecoderVersion = .systemDefault

    /// `.automatic` routing only.
    public var appleSupportCheck: AppleSupportCheck = .oncePerKind

    /// Fallback route only: frames with more pixels than this are developed at half the
    /// width and height. A developed frame takes 8 bytes per pixel.
    ///
    /// The frame is halved once, and only mosaic sensors can be halved. Check
    /// `RawImage.isHalfSize` for the outcome.
    public var halfSizeAbovePixels: Int = 64_000_000

    /// Fallback route only: the most working memory, in megabytes, one decode may use. A
    /// file that needs more throws `RawError.exceedsMemoryLimit` before it is developed.
    ///
    /// The need is worked out from the frame size and the path that will develop it: the
    /// sensor data plus every buffer alive at the peak, about 12 bytes per pixel on the
    /// GPU path and 24 on the CPU path at full size. It covers the decode only. Rendering
    /// the image afterwards is Core Image's memory, and so is all of Apple's route.
    ///
    /// The default shares a quarter of the device's physical memory between
    /// `RawInput.maximumConcurrentDecodes` decodes: just under 1 GB each for two decodes on
    /// a phone with 8 GB.
    public var fallbackMemoryLimitMB = RawDecodeOptions.defaultFallbackMemoryLimitMB

    /// The default for `fallbackMemoryLimitMB` on this device.
    public static var defaultFallbackMemoryLimitMB: Int { DecodeBudget.megabytesPerDecode }

    /// Fallback route only: polled between decoding stages on the decoding thread. Return
    /// true to abandon the decode, which then throws `RawError.cancelled`. The `async`
    /// functions of `RawInput` do this for a canceled task without it being set.
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
