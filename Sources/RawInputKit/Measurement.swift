import CoreImage
import Foundation

/// Helpers for this package's measuring tools and the demo's benchmark mode. Not part of
/// the supported API.
@_spi(Measurement)
public enum RawMeasurement {
    /// Renders every pixel of an image synchronously.
    ///
    /// - Returns: false if the image came out entirely transparent black.
    public static func renderFully(_ image: CIImage, context: CIContext) -> Bool {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return false }
        let pixels = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 16)
        defer { pixels.deallocate() }
        pixels.initializeMemory(as: UInt8.self, repeating: 0)
        context.render(
            image, toBitmap: pixels.baseAddress!, rowBytes: width * 4, bounds: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Sparse scan.
        return stride(from: 0, to: pixels.count, by: 4099).contains { pixels[$0] != 0 }
    }

    /// Current and peak physical memory footprint of the process, in megabytes.
    public static var memoryFootprint: (currentMB: Double, peakMB: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}
