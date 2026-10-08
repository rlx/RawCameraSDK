import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// Runs RawInputKit's blocking calls off the main thread for the views.
///
/// A decode can block for several seconds, so the work runs on its own dispatch queue,
/// off Swift's cooperative thread pool. Cancellation skips work that has not started and
/// abandons a fallback decode between stages. Callers discard results they no longer
/// want, see `DetailModel`.
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

    /// - Parameter sceneLinear: ask Apple's decoder for scene-linear output, which a shared
    ///   look needs. The fallback's output always is.
    static func open(
        _ url: URL, routing: RawDecodeOptions.Routing, sceneLinear: Bool
    ) async throws -> (image: RawImage, seconds: Double) {
        // The dispatch queue cannot see the task's cancellation, so a flag carries it across.
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

    /// Renders for the screen, at most `longEdge` pixels on its longer side. Nothing is
    /// cached. Returns `nil` if Core Image produces nothing.
    ///
    /// - Parameter look: `nil` shows the decoder's own output.
    static func render(
        _ raw: RawImage, look: RawLook?, exposureEV: Double, longEdge: CGFloat = 2400
    ) async -> CGImage? {
        try? await offload {
            let image = look.map { raw.rendered(look: $0, exposureEV: exposureEV) }
                ?? raw.displayImage(exposureEV: exposureEV)
            let scale = min(1, longEdge / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // Not deferred. Core Image would otherwise render at first draw, on the main thread,
            // and hide a failure.
            return context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: nil, deferred: false)
        }
    }

    /// Copies a picked file into `folder` while holding its security-scoped access.
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
