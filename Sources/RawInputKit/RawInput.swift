import CoreGraphics
import CoreImage
import Foundation
import RawShim

/// Opens camera RAW files.
///
/// `open` tries Apple's RAW engine (`CIRAWFilter`) first and uses the fallback, LibRaw
/// with RawInputKit's development, for files Apple cannot develop.
///
/// Files are given as a URL or as `Data`, which is how PhotoKit delivers them.
///
/// The plain functions are synchronous and thread-safe. A decode can take several seconds,
/// so call them off the main thread, or use the `async` forms of `open`, which decode on a
/// background queue and stop when their task is canceled.
public enum RawInput {
    // MARK: Opening

    /// Decodes a RAW file into a linear-light image.
    ///
    /// - Throws: `RawError`. With `.automatic` routing the error is the fallback's.
    public static func open(_ url: URL, options: RawDecodeOptions = RawDecodeOptions()) throws -> RawImage {
        try open(.file(url), options: options, checksAppleSupport: true)
    }

    /// Decodes a RAW file held in memory.
    ///
    /// - Parameter typeHint: the file's uniform type identifier, such as
    ///   `PHAssetResource.uniformTypeIdentifier`. Pass it when you have it. Apple's decoder
    ///   cannot identify Sony, Samsung, Pentax and some Nikon files from their bytes, and
    ///   without a type the library has to find one by trial.
    public static func open(
        data: Data, typeHint: String? = nil, options: RawDecodeOptions = RawDecodeOptions()
    ) throws -> RawImage {
        try open(.memory(data, typeHint: typeHint), options: options, checksAppleSupport: true)
    }

    /// Decodes a RAW file on a background queue, once fewer than
    /// `maximumConcurrentDecodes` other decodes are running.
    ///
    /// Canceling the task stops a fallback decode at its next stage. On the Apple route
    /// the pixels are decoded later, when the image is rendered, so there is little here to
    /// stop. Either way a canceled task gets `RawError.cancelled` and no image.
    public static func open(_ url: URL, options: RawDecodeOptions = RawDecodeOptions()) async throws -> RawImage {
        try await inBackground(.file(url), options: options)
    }

    /// Decodes a RAW file held in memory on a background queue. See `open(_:options:)`.
    public static func open(
        data: Data, typeHint: String? = nil, options: RawDecodeOptions = RawDecodeOptions()
    ) async throws -> RawImage {
        try await inBackground(.memory(data, typeHint: typeHint), options: options)
    }

    /// Opens with Apple's decoder without first testing that it can develop the file. For
    /// benchmarks only. An unsupported file comes back as an image that renders as nothing.
    @_spi(Measurement)
    public static func openAppleUnchecked(_ url: URL, options: RawDecodeOptions = RawDecodeOptions()) throws -> RawImage {
        var options = options
        options.routing = .apple
        return try open(.file(url), options: options, checksAppleSupport: false)
    }

    /// Decodes are blocking and CPU-bound, so they run here and not on Swift's cooperative
    /// pool, whose threads must not block.
    private static let decodeQueue = DispatchQueue(
        label: "RawInputKit.decode", qos: .userInitiated, attributes: .concurrent)

    private static func inBackground(_ source: RawSource, options: RawDecodeOptions) async throws -> RawImage {
        let cancelled = Flag()
        var options = options
        let callersCheck = options.isCancelled
        options.isCancelled = { cancelled.isSet || callersCheck?() == true }
        // Waits here, holding no thread and no memory, while other decodes are running.
        return try await DecodeGate.shared.run { [options] in try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                decodeQueue.async { [options] in
                    let result = Result { () throws -> RawImage in
                        guard !cancelled.isSet else { throw RawError.cancelled }
                        let image = try open(source, options: options, checksAppleSupport: true)
                        // The Apple route never polls.
                        guard !cancelled.isSet else { throw RawError.cancelled }
                        return image
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancelled.set()
        } }
    }

    /// How many `async` decodes may run at once. Further calls wait their turn, in order,
    /// without holding a thread, and leave the queue if their task is canceled.
    ///
    /// The default is one per 4 GB of physical memory, between 1 and 4, which with the
    /// default `fallbackMemoryLimitMB` keeps the fallback's decoding within a quarter of
    /// the device's memory. The blocking functions are not counted or held back: a caller
    /// that runs them on its own threads bounds them itself.
    public static var maximumConcurrentDecodes: Int {
        get { DecodeGate.shared.maximum }
        set { DecodeGate.shared.maximum = newValue }
    }

    private static func open(_ source: RawSource, options: RawDecodeOptions, checksAppleSupport: Bool) throws -> RawImage {
        try source.checkReadable()
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let duration = (clock.now - start).components
            return Double(duration.seconds) + Double(duration.attoseconds) * 1e-18
        }

        let useApple: Bool
        switch options.routing {
        case .automatic:
            switch options.appleSupportCheck {
            case .oncePerKind: useApple = AppleSupport.shared.canDecode(source)
            case .everyFile: useApple = AppleRawDecoder.canDecode(source)
            }
            if !useApple, let handler = options.eventHandler, let header = try? info(source) {
                handler(.appleRejected(camera: header.camera, routine: header.decoderRoutine))
            }
        case .apple:
            // `CIRAWFilter` may return an image that fails silently at render time.
            guard !checksAppleSupport || AppleRawDecoder.canDecode(source) else { throw RawError.appleCannotDecode }
            useApple = true
        case .fallback:
            useApple = false
        }

        if useApple {
            let apple = try AppleRawDecoder.decode(source, options: options)
            // LibRaw cannot parse a few files Apple opens, such as JPEG XL DNG.
            let info = (try? info(source)) ?? RawInfo(size: apple.image.extent.size)
            options.eventHandler?(.opened(camera: info.camera, route: .apple, decoder: apple.decoder, seconds: elapsed()))
            return RawImage(
                image: apple.image, route: .apple, isSceneLinear: options.appleRendering == .linear,
                decoder: apple.decoder, appleDecoderVersion: apple.version, info: info,
                suggestedExposureEV: apple.exposureEV, isHalfSize: false)
        }

        let fallback = try FallbackRawDecoder.decode(source, options: options)
        var image = RawImage(
            image: fallback.image, route: .fallback, fallbackPath: fallback.path, isSceneLinear: true,
            decoder: fallback.decoder, info: fallback.info, suggestedExposureEV: fallback.exposureEV,
            previewDistance: fallback.previewDistance, isHalfSize: fallback.isHalfSize)
        image.backing = fallback.texture.map(TextureBacking.init)
        if image.isColorSuspect, let distance = image.previewDistance {
            options.eventHandler?(.colorSuspect(camera: image.info.camera, distance: distance))
        }
        options.eventHandler?(.opened(
            camera: image.info.camera, route: .fallback, decoder: image.decoder, seconds: elapsed()))
        return image
    }

    // MARK: Metadata and previews

    /// Camera and exposure metadata, read from the file's header only.
    public static func info(_ url: URL) throws -> RawInfo {
        try info(.file(url))
    }

    /// Camera and exposure metadata of a RAW file held in memory.
    public static func info(data: Data, typeHint: String? = nil) throws -> RawInfo {
        try info(.memory(data, typeHint: typeHint))
    }

    private static func info(_ source: RawSource) throws -> RawInfo {
        try source.checkReadable()
        do {
            return RawInfo(try LibRawFile(source).info)
        } catch {
            guard let info = RawInfo(imageSource: source) else { throw error }
            return info
        }
    }

    /// The preview the camera embedded in the file, scaled to fit `maxPixelSize` and rotated
    /// upright. Typically a few milliseconds.
    public static func preview(_ url: URL, maxPixelSize: Int = 1024) throws -> CGImage {
        try preview(.file(url), maxPixelSize: maxPixelSize)
    }

    /// The embedded preview of a RAW file held in memory.
    public static func preview(data: Data, typeHint: String? = nil, maxPixelSize: Int = 1024) throws -> CGImage {
        try preview(.memory(data, typeHint: typeHint), maxPixelSize: maxPixelSize)
    }

    private static func preview(_ source: RawSource, maxPixelSize: Int) throws -> CGImage {
        try source.checkReadable()
        return try RawPreview.make(source, maxPixelSize: maxPixelSize)
    }

    // MARK: Checks

    /// Whether Apple's decoder develops this file on the running OS. Decodes a small region
    /// of the file, which costs a good fraction of a full decode.
    public static func appleCanDecode(_ url: URL) -> Bool {
        AppleRawDecoder.canDecode(.file(url))
    }

    /// Whether Apple's decoder develops a RAW file held in memory.
    public static func appleCanDecode(data: Data, typeHint: String? = nil) -> Bool {
        AppleRawDecoder.canDecode(.memory(data, typeHint: typeHint))
    }

    /// Distance between an image's colors and the embedded preview of the file it came
    /// from, as in `RawImage.previewDistance`. Renders the image at a small size. `nil`
    /// when the file has no embedded preview.
    public static func previewDistance(of image: CIImage, forFileAt url: URL) -> Double? {
        // ImageIO is not used: it can synthesize a preview by developing the file.
        guard let file = try? LibRawFile(url),
              let preview = try? RawPreview.embedded(in: file, maxPixelSize: 512)
        else { return nil }
        return PreviewAgreement.distance(image, preview: preview)
    }

    /// The fallback decoder's version, e.g. "LibRaw 0.22.2". Store it with an edit made on
    /// the fallback route, as `RawImage.appleDecoderVersion` is stored for Apple's.
    public static var fallbackVersion: String { "LibRaw \(FallbackRawDecoder.version)" }
}

/// A flag one thread sets and another reads.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false  // guarded by `lock`

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
