import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// Runs RawInputKit's blocking calls off the main thread for the views.
///
/// RawInputKit is synchronous: a decode occupies its thread for anything from a tenth of a
/// second to several seconds. That work goes to a dispatch queue of its own instead of
/// Swift's cooperative thread pool, which is sized to the CPU count and is not meant to be
/// blocked.
///
/// Cancellation reaches the work in three ways: work that has not started is skipped, a
/// fallback decode in flight is abandoned between stages (the slow ones take seconds), and
/// callers discard results they no longer want. See `DetailModel` for the last.
enum Develop {
    private static let queue = DispatchQueue(label: "RawInputDemo.develop", qos: .userInitiated, attributes: .concurrent)
    private static let context = CIContext()

    private static func offload<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// The embedded preview; `nil` if the file has none or the task was cancelled.
    static func thumbnail(_ url: URL) async -> CGImage? {
        try? await offload { try RawInput.preview(url, maxPixelSize: 600) }
    }

    /// - Parameter sceneLinear: ask Apple's decoder for scene-linear output too, which is
    ///   what a shared look needs. The fallback's output always is.
    static func open(
        _ url: URL, routing: RawDecodeOptions.Routing, sceneLinear: Bool
    ) async throws -> (image: RawImage, seconds: Double) {
        // The decode runs on a dispatch queue, outside the task, so it cannot see the
        // task's cancellation directly; a flag carries it across.
        let cancelled = Flag()
        return try await withTaskCancellationHandler {
            try await offload {
                var options = RawDecodeOptions()
                options.routing = routing
                options.appleRendering = sceneLinear ? .linear : .standard
                options.isCancelled = { cancelled.isSet }
                let start = ContinuousClock.now
                let image = try RawInput.open(url, options: options)
                let elapsed = (ContinuousClock.now - start).components
                return (image, Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Renders for the screen, at most `longEdge` pixels on its longer side.
    ///
    /// Exposure and the look are applied to the linear image and nothing is cached, so each
    /// call is the operation an editor would run on the decoder's output. Returns `nil` if
    /// Core Image produces nothing, which is how a file Apple's decoder cannot really
    /// develop shows up.
    ///
    /// - Parameter look: `nil` shows the decoder's own output, with no shared rendering.
    static func render(
        _ raw: RawImage, look: RawLook?, exposureEV: Double, longEdge: CGFloat = 2400
    ) async -> CGImage? {
        try? await offload {
            let image = look.map { raw.rendered(look: $0, exposureEV: exposureEV) }
                ?? raw.displayImage(exposureEV: exposureEV)
            let scale = min(1, longEdge / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // Not deferred: by default Core Image would postpone the render until the image
            // is first drawn, which would move it onto the main thread and hide a failure.
            return context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: nil, deferred: false)
        }
    }

    /// Copies a file the user picked into `folder`, holding its security-scoped access for
    /// the duration of the copy.
    static func importCopy(of url: URL, into folder: URL) async throws -> URL {
        try await offload {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
    }

    /// Physical memory the app is using right now, in megabytes.
    static var memoryFootprintMB: Double { RawMeasurement.memoryFootprint.currentMB }
}

/// A boolean that can be set from one thread and read from another.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
