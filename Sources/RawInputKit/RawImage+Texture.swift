import CoreImage
import Metal

extension RawImage {
    /// Renders the image into a new texture on `device`: 16-bit float RGBA in extended
    /// linear sRGB, with the top row of the picture first. On the Apple route the decode
    /// runs here. Throws `RawError.renderFailed` if the texture cannot be allocated.
    public func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let extent = image.extent.integral
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard extent.width > 0, extent.height > 0, let texture = device.makeTexture(descriptor: descriptor),
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else { throw RawError.renderFailed(reason: "could not allocate the texture") }

        // Core Image's origin is bottom-left and a texture's is top-left.
        let flipped = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -extent.height))
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        context.render(
            flipped, to: texture, commandBuffer: nil,
            bounds: CGRect(origin: .zero, size: extent.size), colorSpace: colorSpace)
        return texture
    }
}
