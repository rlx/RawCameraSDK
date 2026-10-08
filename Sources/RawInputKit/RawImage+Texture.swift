import CoreImage
import Metal

extension RawImage {
    /// Renders the image into a new Metal texture, for an engine that does its own
    /// processing on the GPU and has no use for Core Image.
    ///
    /// The texture is 16-bit float RGBA in extended linear sRGB: the same values `image`
    /// holds, with the top row of the picture as the texture's first row. On the fallback's
    /// GPU path this is one blit; on the Apple route it is where the decode actually runs.
    ///
    /// - Parameter device: the device the engine renders with. The texture is created on it.
    public func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let extent = image.extent.integral
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard extent.width > 0, extent.height > 0, let texture = device.makeTexture(descriptor: descriptor),
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else { throw RawError.renderFailed(reason: "could not allocate the texture") }

        // Core Image's origin is bottom-left and a texture's is top-left; flip on the way in.
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
