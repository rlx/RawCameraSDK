import CoreImage
import simd

let testContext = CIContext()

/// Average linear sRGB colour of the central half of an image.
func centreColor(_ image: CIImage) -> SIMD3<Float> {
    let crop = image.extent.insetBy(dx: image.extent.width / 4, dy: image.extent.height / 4)
    let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: crop)])
    var pixel = [Float](repeating: 0, count: 4)
    testContext.render(
        average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
    return SIMD3(pixel[0], pixel[1], pixel[2])
}

/// Every pixel of a small image as linear sRGB, first row at the top.
func pixels(of image: CIImage) -> [[SIMD3<Float>]] {
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var buffer = [Float](repeating: 0, count: width * height * 4)
    testContext.render(
        image, toBitmap: &buffer, rowBytes: width * 16, bounds: image.extent, format: .RGBAf,
        colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
    return (0..<height).map { y in
        (0..<width).map { x in
            let i = (y * width + x) * 4
            return SIMD3(buffer[i], buffer[i + 1], buffer[i + 2])
        }
    }
}

/// Red and green as fractions of the channel sum.
func chromaticity(_ color: SIMD3<Float>) -> SIMD2<Float> {
    SIMD2(color.x, color.y) / color.sum()
}
