import CoreImage

/// Renders every pixel of an image, synchronously, the way an export would.
///
/// The obvious call, `CIContext.createCGImage`, is not a measurement: it returns at once
/// and does the work when the image's pixels are first read. Rendering into a bitmap the
/// caller owns has no such deferral, so the time it takes is the time the render takes.
enum FullRender {
    /// Returns false if the image came out entirely transparent black, which is how a file
    /// a decoder cannot really develop shows up.
    static func run(_ image: CIImage, context: CIContext) -> Bool {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return false }
        let pixels = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 16)
        defer { pixels.deallocate() }
        pixels.initializeMemory(as: UInt8.self, repeating: 0)
        context.render(
            image, toBitmap: pixels.baseAddress!, rowBytes: width * 4, bounds: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // A sparse scan is enough to tell a picture from nothing.
        return stride(from: 0, to: pixels.count, by: 4099).contains { pixels[$0] != 0 }
    }
}
