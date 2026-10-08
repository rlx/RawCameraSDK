import CoreImage
import Foundation
import RawInputKit

/// `rawprobe looks`: both decoders with and without the shared rendering step.
///
/// The top row is each decoder's own output. The rows below take scene-linear data from
/// both through the same `RawLook`, and the two columns should be hard to tell apart.
enum Looks {
    static func run(input: URL, output: URL) throws {
        let appleOwn = try Compare.open(input, .apple)
        let appleLinear = try Compare.open(input, .apple, linear: true)
        let fallback = try Compare.open(input, .fallback)

        func row(_ title: String, _ apple: CIImage, _ fallbackImage: CIImage) -> [ContactSheet.Cell] {
            [
                ContactSheet.Cell(caption: "Apple's decoder · \(title)", image: apple),
                ContactSheet.Cell(caption: "Fallback · \(title)", image: fallbackImage),
            ]
        }
        try ContactSheet.write(
            rows: [
                row("its own output", appleOwn.displayImage(), fallback.displayImage()),
                row("shared rendering, neutral", appleLinear.rendered(look: .neutral), fallback.rendered(look: .neutral)),
                row("shared rendering, film", appleLinear.rendered(look: .film), fallback.rendered(look: .film)),
            ],
            cellSize: CGSize(width: 720, height: 0), to: output)
        print("\(fallback.info.camera) -> \(output.lastPathComponent)")
    }
}
