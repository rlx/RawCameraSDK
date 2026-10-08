import CoreImage
import Foundation
import Metal

extension RawImage {
    /// The image as a texture on `device`: 16-bit float RGBA, linear, with the top row of
    /// the picture first.
    ///
    /// When the fallback's GPU path developed the image on this device, the picture is
    /// upright and no color space is asked for, the texture that path produced is returned
    /// as it is, with no render and no copy. It is the storage behind `image`, so writing
    /// to it changes `image` too. In every other case the image is rendered into a new
    /// texture, and on the Apple route the decode runs here.
    ///
    /// - Parameter colorSpace: a linear RGB space for the texture's values, such as
    ///   `CGColorSpace.extendedLinearDisplayP3`. The default is extended linear sRGB, where
    ///   colors outside sRGB have components below 0.
    /// - Throws: `RawError.renderFailed` if the texture cannot be allocated.
    public func makeTexture(device: MTLDevice, colorSpace: CGColorSpace? = nil) throws -> MTLTexture {
        if colorSpace == nil, info.orientation == .up, let texture = backing?.texture, texture.device === device {
            return texture
        }

        let extent = image.extent.integral
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard extent.width > 0, extent.height > 0, let texture = device.makeTexture(descriptor: descriptor),
              let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else { throw RawError.renderFailed(reason: "could not allocate the texture") }

        // Core Image's origin is bottom-left and a texture's is top-left.
        let flipped = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -extent.height))
        TextureContexts.shared.context(for: device).render(
            flipped, to: texture, commandBuffer: nil,
            bounds: CGRect(origin: .zero, size: extent.size), colorSpace: colorSpace)
        return texture
    }
}

/// Holds a Metal texture in a `Sendable` value. Metal textures are safe to share between
/// threads as long as reads and writes are ordered by the caller.
final class TextureBacking: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
}

/// One Core Image context per Metal device, kept for the life of the process. Creating a
/// context costs tens of milliseconds and each one holds its own compiled kernels.
private final class TextureContexts: @unchecked Sendable {
    static let shared = TextureContexts()

    private let lock = NSLock()
    private var contexts: [UInt64: CIContext] = [:]  // by device registry ID, guarded by `lock`

    func context(for device: MTLDevice) -> CIContext {
        lock.withLock {
            if let context = contexts[device.registryID] { return context }
            let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            contexts[device.registryID] = context
            return context
        }
    }
}
