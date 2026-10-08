import CoreImage
import Foundation
import RawInputKit

/// Runs RawInputKit's blocking calls off the main thread for the views.
///
/// RawInputKit is synchronous: a decode occupies its thread for anything from a tenth of a
/// second to several seconds. That work goes to a dispatch queue of its own instead of
/// Swift's cooperative thread pool, which is sized to the CPU count and is not meant to be
/// blocked.
///
/// A decode in flight cannot be interrupted, so cancellation here means two things: work
/// that has not started is skipped, and callers discard results they no longer want. See
/// `DetailModel` for the second half.
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

    static func open(_ url: URL, routing: RawDecodeOptions.Routing) async throws -> RawImage {
        try await offload {
            var options = RawDecodeOptions()
            options.routing = routing
            return try RawInput.open(url, options: options)
        }
    }

    /// Renders for the screen, at most `longEdge` pixels on its longer side.
    ///
    /// Exposure is applied to the linear image and nothing is cached, so each call is the
    /// operation an editor would run on the decoder's output. Returns `nil` if Core Image
    /// produces nothing, which is how a file Apple's decoder cannot really develop shows up.
    static func render(_ raw: RawImage, exposureEV: Double, longEdge: CGFloat = 2400) async -> CGImage? {
        try? await offload {
            let image = raw.displayImage(exposureEV: exposureEV)
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

    /// Physical memory the app is using right now, in megabytes: the figure iOS judges an
    /// app by when it decides what to terminate.
    static var memoryFootprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
