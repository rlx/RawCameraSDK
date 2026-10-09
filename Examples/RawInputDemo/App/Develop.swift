import CoreImage
import Foundation
@_spi(Measurement) import RawInputKit

/// Runs RawInputKit's blocking calls off the main thread for the views.
///
/// Decoding uses the library's async `open`, which stops with its task. The other calls
/// can block too, so they run on a dispatch queue here, off Swift's cooperative thread
/// pool. Callers discard results they no longer want, see `DetailModel`.
enum Develop {
    private static let queue = DispatchQueue(label: "RawInputDemo.develop", qos: .userInitiated, attributes: .concurrent)
    private static let context = CIContext()

    private static func offload<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// The embedded preview; `nil` if the file has none or the task was canceled.
    static func thumbnail(_ item: RawItem) async -> CGImage? {
        try? await offload {
            switch item.origin {
            case .file:
                try RawInput.preview(item.url, maxPixelSize: 600)
            case .photoLibrary(let typeIdentifier):
                try RawInput.preview(data: bytes(of: item), typeHint: typeIdentifier, maxPixelSize: 600)
            }
        }
    }

    /// A photo-library item's bytes, mapped from the copy the demo keeps on disk.
    private static func bytes(of item: RawItem) throws -> Data {
        try Data(contentsOf: item.url, options: .mappedIfSafe)
    }

    /// Writes bytes from the photo library to a file named `raw` in `folder`.
    static func store(_ data: Data, in folder: URL) async throws -> URL {
        try await offload {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "raw")
            try data.write(to: file)
            return file
        }
    }

    /// - Parameter sceneLinear: ask Apple's decoder for scene-linear output, which a shared
    ///   look needs. The fallback's output always is.
    static func open(
        _ item: RawItem, routing: RawDecodeOptions.Routing, sceneLinear: Bool
    ) async throws -> (image: RawImage, seconds: Double) {
        var options = RawDecodeOptions()
        options.routing = routing
        options.appleRendering = sceneLinear ? .linear : .standard
        let start = ContinuousClock.now
        // The library's async `open` decodes on its own queue and stops with this task.
        let image: RawImage
        switch item.origin {
        case .file:
            image = try await RawInput.open(item.url, options: options)
        case .photoLibrary(let typeIdentifier):
            image = try await RawInput.open(data: bytes(of: item), typeHint: typeIdentifier, options: options)
        }
        let elapsed = (ContinuousClock.now - start).components
        return (image, Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
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
