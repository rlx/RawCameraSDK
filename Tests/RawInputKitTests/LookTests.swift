import CoreImage
import Testing
import simd
@testable import RawInputKit

@Suite("Looks")
struct LookTests {
    static let grays = stride(from: 0.0, through: 1.0, by: 0.05).map { SIMD3<Double>(repeating: $0) }

    @Test func neutralKeepsBlackWhiteAndGrayNeutral() {
        #expect(simd_distance(RawLook.neutral.apply(.zero), .zero) < 1e-9)
        #expect(simd_distance(RawLook.neutral.apply(.one), .one) < 1e-9)
        for gray in Self.grays {
            let out = RawLook.neutral.apply(gray)
            #expect(abs(out.x - out.y) < 1e-9 && abs(out.y - out.z) < 1e-9, "a gray stays gray")
        }
    }

    @Test(arguments: [RawLook.neutral, .film])
    func toneCurveNeverReverses(_ look: RawLook) {
        let lumas = Self.grays.map { look.apply($0) }.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }
        for (darker, lighter) in zip(lumas, lumas.dropFirst()) {
            #expect(lighter >= darker)
        }
    }

    @Test func contrastDarkensShadowsAndBrightensHighlights() {
        #expect(RawLook.neutral.apply(SIMD3(repeating: 0.2)).x < 0.2)
        #expect(RawLook.neutral.apply(SIMD3(repeating: 0.8)).x > 0.8)
    }

    @Test func filmLiftsBlackAndTintsTheExtremes() {
        let black = RawLook.film.apply(.zero), white = RawLook.film.apply(.one)
        #expect(black.min() > 0.02, "faded: black is lifted off zero")
        #expect(black.z > black.x, "shadows lean toward blue")
        #expect(white.x > white.z, "highlights lean toward red")
    }

    @Test func desaturationPullsColorTowardGray() {
        let red = SIMD3<Double>(0.8, 0.2, 0.2)
        let spread = { (c: SIMD3<Double>) in c.max() - c.min() }
        #expect(spread(RawLook(contrast: 0, saturation: 0.5).apply(red)) < spread(red))
        #expect(spread(RawLook(contrast: 0, saturation: 0).apply(red)) < 1e-9)
    }

    @Test func lookupTableHasCoreImageLayout() {
        let n = RawLook.cubeSize
        let data = RawLook(contrast: 0).cubeData()
        #expect(data.count == n * n * n * 4 * MemoryLayout<Float>.stride)
        // With no adjustments the table is the identity. Red varies fastest, blue slowest.
        data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            func entry(r: Int, g: Int, b: Int) -> SIMD3<Float> {
                let i = ((b * n + g) * n + r) * 4
                return SIMD3(values[i], values[i + 1], values[i + 2])
            }
            #expect(entry(r: n - 1, g: 0, b: 0) == SIMD3(1, 0, 0))
            #expect(entry(r: 0, g: n - 1, b: 0) == SIMD3(0, 1, 0))
            #expect(entry(r: 0, g: 0, b: n - 1) == SIMD3(0, 0, 1))
        }
    }

    @Test func renderedImageMatchesTheMaths() {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var pixel = [UInt8](repeating: 0, count: 4)
        testContext.render(
            RawLook.film.filter(on: gray), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let expected = RawLook.film.apply(SIMD3(repeating: 0.5))
        for channel in 0..<3 {
            #expect(abs(Double(pixel[channel]) / 255 - expected[channel]) < 0.02)
        }
    }
}
