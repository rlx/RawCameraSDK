import CoreImage
import Foundation
import RawInputKit

/// `rawprobe render`: develops one file and saves a JPEG of what the demo app would show.
enum Render {
    static func run(input: URL, output: URL, route: String?) throws {
        var options = RawDecodeOptions()
        switch route {
        case "apple": options.routing = .apple
        case "fallback": options.routing = .fallback
        default: options.routing = .automatic
        }
        let start = ContinuousClock.now
        let raw = try RawInput.open(input, options: options)
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        let display = raw.displayImage()
        let scale = min(1, 2048 / max(display.extent.width, display.extent.height))
        try CIContext().writeJPEGRepresentation(
            of: display.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: output,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        print("\(raw.decoder), \(Int(raw.image.extent.width))x\(Int(raw.image.extent.height)), "
            + String(format: "%+.2f EV, opened in %.2f s", raw.suggestedExposureEV, seconds))
    }
}
