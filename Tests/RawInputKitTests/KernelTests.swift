import CoreImage
import Testing
import simd
@testable import RawInputKit

/// The GPU kernel against hand-built mosaics with known answers. A real file developed
/// with the pattern shifted by a pixel, or flipped top to bottom, still looks plausible.
@Suite("Metal kernel", .enabled(if: MetalDevelop.shared != nil, "needs a GPU"))
struct KernelTests {
    /// A `width` x `height` picture inside a larger raw plane. The border stands in for
    /// masked sensor pixels and holds a value that corrupts the result if the kernel reads it.
    struct Mosaic {
        static let origin = SIMD2<UInt32>(2, 1)
        static let black: Float = 64, white: Float = 1064

        let width: Int, height: Int
        let pattern: SIMD4<UInt32>
        /// Black level at each of the four mosaic positions.
        let blackLevels: SIMD4<Float>
        var samples: [UInt16]
        var rawWidth: Int { width + 5 }
        var rawHeight: Int { height + 3 }

        /// `color(x, y)` is the scene colour at a picture coordinate, 0...1 per channel.
        init(
            width: Int = 8, height: Int = 8, pattern: SIMD4<UInt32>,
            blackLevels: SIMD4<Float> = SIMD4(repeating: Mosaic.black), color: (Int, Int) -> SIMD3<Float>
        ) {
            self.width = width
            self.height = height
            self.pattern = pattern
            self.blackLevels = blackLevels
            samples = []
            samples = [UInt16](repeating: .max, count: rawWidth * rawHeight)
            for y in 0..<height {
                for x in 0..<width {
                    let position = (y & 1) * 2 + (x & 1)
                    let channel = Int(pattern[position])
                    let black = blackLevels[position]
                    let level = black + color(x, y)[channel] * (Self.white - black)
                    samples[(y + Int(Self.origin.y)) * rawWidth + x + Int(Self.origin.x)] = UInt16(level)
                }
            }
        }

        func develop(
            halfSize: Bool = false, whiteBalance: SIMD3<Float> = SIMD3(1, 1, 1)
        ) throws -> [[SIMD3<Float>]] {
            let parameters = MetalDevelop.Parameters(
                black: blackLevels, whiteBalance: SIMD4(whiteBalance, 1),
                matrixRow0: SIMD4(1, 0, 0, 0), matrixRow1: SIMD4(0, 1, 0, 0), matrixRow2: SIMD4(0, 0, 1, 0),
                pattern: pattern, origin: Self.origin, size: SIMD2(UInt32(width), UInt32(height)),
                white: Self.white)
            let image = try samples.withUnsafeBytes { bytes in
                try #require(MetalDevelop.shared).develop(
                    mosaic: bytes.baseAddress!, rowBytes: rawWidth * 2, rawWidth: rawWidth, rawHeight: rawHeight,
                    parameters: parameters, halfSize: halfSize)
            }
            return pixels(of: image)
        }
    }

    /// The four Bayer cell arrangements, in reading order.
    static let patterns: [SIMD4<UInt32>] = [
        SIMD4(0, 1, 1, 2),  // RGGB
        SIMD4(2, 1, 1, 0),  // BGGR
        SIMD4(1, 0, 2, 1),  // GRBG
        SIMD4(1, 2, 0, 1),  // GBRG
    ]

    static let flat = SIMD3<Float>(0.2, 0.5, 0.8)
    /// 16-bit float output and integer sample levels both round.
    static let tolerance: Float = 0.004

    @Test(arguments: patterns)
    func flatColorSurvivesDemosaic(_ pattern: SIMD4<UInt32>) throws {
        let developed = try Mosaic(pattern: pattern) { _, _ in Self.flat }.develop()
        #expect(developed.count == 8 && developed[0].count == 8)
        // Every pixel is checked, so a wrong pattern index or origin, or a read of the
        // masked border, shows up.
        for row in developed {
            for pixel in row {
                #expect(simd_distance(pixel, Self.flat) < Self.tolerance)
            }
        }
    }

    @Test(arguments: patterns)
    func halfSizeMergesEachCell(_ pattern: SIMD4<UInt32>) throws {
        let developed = try Mosaic(pattern: pattern) { _, _ in Self.flat }.develop(halfSize: true)
        #expect(developed.count == 4 && developed[0].count == 4)
        for pixel in developed.joined() {
            #expect(simd_distance(pixel, Self.flat) < Self.tolerance)
        }
    }

    /// Black level is per mosaic position. The two greens of a cell often differ.
    @Test(arguments: patterns)
    func perPositionBlackLevelsAreSubtracted(_ pattern: SIMD4<UInt32>) throws {
        let developed = try Mosaic(pattern: pattern, blackLevels: SIMD4(40, 64, 88, 120)) { _, _ in Self.flat }
            .develop()
        for pixel in developed.joined() {
            #expect(simd_distance(pixel, Self.flat) < Self.tolerance)
        }
    }

    @Test func topOfPictureIsTopOfImage() throws {
        // Dark above, bright below. Metal and Core Image disagree about which way is up.
        let developed = try Mosaic(pattern: Self.patterns[0]) { _, y in SIMD3(repeating: y < 4 ? 0.1 : 0.9) }
            .develop()
        #expect(developed[0][4].y < 0.2)
        #expect(developed[7][4].y > 0.8)
    }

    @Test func leftOfPictureIsLeftOfImage() throws {
        let developed = try Mosaic(pattern: Self.patterns[0]) { x, _ in SIMD3(repeating: x < 4 ? 0.1 : 0.9) }
            .develop()
        #expect(developed[4][0].y < 0.2)
        #expect(developed[4][7].y > 0.8)
    }

    @Test func whiteBalanceScalesItsChannel() throws {
        let developed = try Mosaic(pattern: Self.patterns[0]) { _, _ in SIMD3(0.2, 0.4, 0.2) }
            .develop(whiteBalance: SIMD3(2, 1, 1.5))
        #expect(simd_distance(developed[4][4], SIMD3(0.4, 0.4, 0.3)) < Self.tolerance)
    }

    @Test func blownHighlightsStayNeutral() throws {
        // White balance must not push red and blue past green on a saturated sensor, or
        // highlights turn magenta.
        let developed = try Mosaic(pattern: Self.patterns[0]) { _, _ in SIMD3(1, 1, 1) }
            .develop(whiteBalance: SIMD3(2.2, 1, 1.6))
        #expect(simd_distance(developed[4][4], SIMD3(1, 1, 1)) < Self.tolerance)
    }

    /// The Rust crate runs the same case file against the WGSL kernel under wgpu.
    @Test(arguments: ConformanceCase.all)
    func passesSharedConformanceCase(_ test: ConformanceCase) throws {
        let p = test.params
        func lane4(_ values: [Float]) -> SIMD4<Float> { SIMD4(values[0], values[1], values[2], values[3]) }
        let parameters = MetalDevelop.Parameters(
            black: lane4(p.black), whiteBalance: lane4(p.whiteBalance), matrixRow0: lane4(p.matrix[0]),
            matrixRow1: lane4(p.matrix[1]), matrixRow2: lane4(p.matrix[2]),
            pattern: SIMD4(p.pattern[0], p.pattern[1], p.pattern[2], p.pattern[3]),
            origin: SIMD2(p.origin[0], p.origin[1]), size: SIMD2(p.size[0], p.size[1]), white: p.white)
        let image = try test.mosaic.withUnsafeBytes { bytes in
            try #require(MetalDevelop.shared).develop(
                mosaic: bytes.baseAddress!, rowBytes: test.rawWidth * 2, rawWidth: test.rawWidth,
                rawHeight: test.rawHeight, parameters: parameters, halfSize: test.halfSize)
        }
        let developed = pixels(of: image)
        let tolerance = ConformanceCase.tolerance

        if let expected = test.everyPixel {
            for pixel in developed.joined() {
                #expect(simd_distance(pixel, SIMD3(expected[0], expected[1], expected[2])) < tolerance)
            }
        }
        for check in test.pixels ?? [] {
            let expected = SIMD3(check.rgb[0], check.rgb[1], check.rgb[2])
            #expect(simd_distance(developed[check.y][check.x], expected) < tolerance)
        }
    }

    /// If these offsets move, `Params` in the shader source has to move with them.
    @Test func parameterLayoutMatchesShader() {
        typealias Layout = MemoryLayout<MetalDevelop.Parameters>
        #expect(Layout.offset(of: \.black) == 0)
        #expect(Layout.offset(of: \.whiteBalance) == 16)
        #expect(Layout.offset(of: \.matrixRow0) == 32)
        #expect(Layout.offset(of: \.pattern) == 80)
        #expect(Layout.offset(of: \.origin) == 96)
        #expect(Layout.offset(of: \.size) == 104)
        #expect(Layout.offset(of: \.white) == 112)
        #expect(Layout.stride == 128)
    }
}

/// One entry of Conformance/kernel-cases.json, written by Scripts/conformance.py.
struct ConformanceCase: Decodable, CustomTestStringConvertible {
    struct Params: Decodable {
        let black, whiteBalance: [Float]
        let matrix: [[Float]]
        let pattern, origin, size: [UInt32]
        let white: Float
    }

    struct PixelCheck: Decodable {
        let x, y: Int
        let rgb: [Float]
    }

    let name: String
    let halfSize: Bool
    let rawWidth, rawHeight: Int
    let mosaic: [UInt16]
    let params: Params
    let everyPixel: [Float]?
    let pixels: [PixelCheck]?

    var testDescription: String { name }

    private struct Document: Decodable {
        let tolerance: Float
        let cases: [ConformanceCase]
    }

    private static let document: Document? = {
        // From the repository, or from the test bundle on a device.
        let inRepository = Fixtures.root.appending(path: "Conformance/kernel-cases.json")
        let bundled = Bundle.allBundles.lazy.compactMap { $0.url(forResource: "kernel-cases", withExtension: "json") }
        return ([inRepository] + Array(bundled)).lazy
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(Document.self, from: $0) }
            .first
    }()

    static var all: [ConformanceCase] { document?.cases ?? [] }
    static var tolerance: Float { document?.tolerance ?? 0.004 }
}
