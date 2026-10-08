import Foundation
import ImageIO
import Testing
@testable import RawInputKit

@Suite("Exposure estimate")
struct ExposureEstimateTests {
    @Test func liftsBrightestPercentToJustUnderWhite() {
        var estimate = ExposureEstimate()
        for _ in 0..<1000 { estimate.add(0.225) }
        // 0.9 / 0.225 is a factor of four: two stops.
        #expect(abs(estimate.suggestedEV - 2) < 0.02)
    }

    @Test func neverDarkens() {
        var estimate = ExposureEstimate()
        for _ in 0..<1000 { estimate.add(1) }
        #expect(estimate.suggestedEV == 0)
    }

    @Test func limitsTheBoostForNearBlackFrames() {
        var estimate = ExposureEstimate()
        for _ in 0..<1000 { estimate.add(0.002) }
        #expect(estimate.suggestedEV <= 4)
    }

    @Test func emptyAndBlackFramesGetNoBoost() {
        #expect(ExposureEstimate().suggestedEV == 0)
        var black = ExposureEstimate()
        for _ in 0..<100 { black.add(0) }
        #expect(black.suggestedEV == 0)
    }

    /// A file whose white level equals its black level makes every sample 0/0. Converting
    /// that to an integer would crash the process, on input an attacker controls.
    @Test func ignoresNonFiniteSamples() {
        var estimate = ExposureEstimate()
        estimate.add(.nan)
        estimate.add(.infinity)
        estimate.add(-.infinity)
        #expect(estimate.percentile(0.99) == 0)
        estimate.add(0.45)
        #expect(abs(estimate.suggestedEV - 1) < 0.02)
    }
}

@Suite("Metadata")
struct MetadataTests {
    /// dcraw flip codes are three bits: mirror horizontally, mirror vertically, transpose.
    @Test(arguments: [
        (Int32(0), CGImagePropertyOrientation.up), (1, .upMirrored), (2, .downMirrored), (3, .down),
        (4, .leftMirrored), (5, .left), (6, .right), (7, .rightMirrored),
    ])
    func translatesFlipCodes(_ flip: Int32, _ expected: CGImagePropertyOrientation) {
        #expect(RawInfo.orientation(flip: flip) == expected)
    }

    @Test func cameraNameDoesNotRepeatTheMake() {
        #expect(RawInfo(make: "Canon", model: "Canon EOS R5", width: 1, height: 1).camera == "Canon EOS R5")
        #expect(RawInfo(make: "Sony", model: "ILCE-7M4", width: 1, height: 1).camera == "Sony ILCE-7M4")
        #expect(RawInfo(width: 1, height: 1).camera == "Unknown camera")
    }
}

@Suite("Robustness")
struct RobustnessTests {
    private func temporaryFile(_ data: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    /// Every entry point refuses the file, with an error and without crashing.
    private func expectRejected(_ url: URL) {
        #expect(!RawInput.appleCanDecode(url))
        for routing in [RawDecodeOptions.Routing.automatic, .apple, .fallback] {
            var options = RawDecodeOptions()
            options.routing = routing
            #expect(throws: RawError.self) { try RawInput.open(url, options: options) }
        }
        #expect(throws: RawError.self) { try RawInput.info(url) }
        #expect(throws: RawError.self) { try RawInput.preview(url) }
    }

    @Test func missingFileSaysSo() {
        let url = URL(fileURLWithPath: "/nonexistent/file.arw")
        expectRejected(url)
        #expect(throws: RawError.fileUnreadable(url)) { try RawInput.open(url) }
    }

    @Test func emptyFile() throws {
        let url = try temporaryFile(Data(), extension: "dng")
        defer { try? FileManager.default.removeItem(at: url) }
        expectRejected(url)
    }

    @Test func randomBytes() throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<65_536).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let url = try temporaryFile(Data(bytes), extension: "cr3")
        defer { try? FileManager.default.removeItem(at: url) }
        expectRejected(url)
    }

    /// A card pulled mid-copy: the header parses, then the sensor data runs out. Decoders
    /// differ in whether they notice, so the only firm requirement is not crashing; a
    /// file that does decode must at least produce a real image.
    @Test(arguments: Fixtures.samples)
    func truncatedFileDoesNotCrash(_ sample: Fixtures.Sample) throws {
        let data = try Data(contentsOf: sample.url, options: .mappedIfSafe)
        let url = try temporaryFile(data.prefix(data.count / 3), extension: sample.url.pathExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = RawDecodeOptions()
        options.routing = .fallback
        if let raw = try? RawInput.open(url, options: options) {
            #expect(!raw.image.extent.isEmpty)
        }
    }
}
