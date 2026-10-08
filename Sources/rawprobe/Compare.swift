import CoreImage
import Foundation
import RawInputKit

/// `rawprobe compare`: both decoders' own output for one file, side by side, so the
/// difference in look and detail can be judged by eye.
///
/// Apple on the left, the fallback on the right; the whole frame on top and a 1:1 crop from
/// the centre underneath. Nothing is done to either image beyond what its decoder did,
/// apart from the fallback's default exposure.
enum Compare {
    static func run(input: URL, output: URL) throws {
        let apple = try open(input, .apple), fallback = try open(input, .fallback)
        let pictures = [apple, fallback].map { (caption: $0.decoder, image: $0.displayImage()) }
        try ContactSheet.write(
            rows: [
                pictures.map { ContactSheet.Cell(caption: $0.caption, image: $0.image) },
                pictures.map { ContactSheet.Cell(image: $0.image, framing: .centreCrop) },
            ],
            cellSize: CGSize(width: 900, height: 520), to: output)
        print("\(apple.info.camera): \(apple.decoder) vs \(fallback.decoder) -> \(output.lastPathComponent)")
    }

    /// Opens at full resolution on either route, with Apple's output optionally scene-linear.
    static func open(_ url: URL, _ routing: RawDecodeOptions.Routing, linear: Bool = false) throws -> RawImage {
        var options = RawDecodeOptions()
        options.routing = routing
        options.appleRendering = linear ? .linear : .standard
        // Compare like with like: never let the pixel threshold halve the fallback.
        options.halfSizeAbovePixels = .max
        return try RawInput.open(url, options: options)
    }
}
