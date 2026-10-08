import CoreImage
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

@Suite("Preview agreement")
struct PreviewAgreementTests {
    /// A flat mid-grey card with a coloured patch, as a stand-in for a photograph.
    private func picture(tint: CIColor? = nil) -> CIImage {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        let grey = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: frame)
        let patch = CIImage(color: CIColor(red: 0.7, green: 0.3, blue: 0.2))
            .cropped(to: CGRect(x: 60, y: 40, width: 80, height: 60))
        let composed = patch.composited(over: grey)
        guard let tint else { return composed }
        return composed.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: tint).cropped(to: frame),
        ])
    }

    private func distance(_ image: CIImage, from reference: CIImage) throws -> Double {
        let preview = try #require(testContext.createCGImage(reference, from: reference.extent))
        return try #require(PreviewAgreement.distance(image, preview: preview, context: testContext))
    }

    @Test func identicalPicturesAgree() throws {
        #expect(try distance(picture(), from: picture()) < 0.01)
    }

    /// The camera's preview has its own brightness and contrast; only hue is evidence.
    @Test func brightnessAloneIsNotDisagreement() throws {
        // About two thirds of a stop darker. (Near black the measure deliberately loses
        // interest, since hue there is mostly noise, so the test stays out of the shadows.)
        let darker = picture(tint: CIColor(red: 0.8, green: 0.8, blue: 0.8))
        #expect(try distance(darker, from: picture()) < 0.03)
    }

    /// What a wrong black level or white balance looks like: a cast over the whole frame.
    @Test func colorCastIsFlagged() throws {
        let pink = picture(tint: CIColor(red: 1, green: 0.55, blue: 0.8))
        #expect(try distance(pink, from: picture()) > RawImage.suspectPreviewDistance)
    }

    @Test func upsideDownPictureIsFlagged() throws {
        // Top half bright red, bottom half blue: unmistakable once flipped.
        let frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        let red = CIImage(color: CIColor(red: 0.8, green: 0.1, blue: 0.1)).cropped(to: frame)
        let blue = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 80))
        let upright = blue.composited(over: red)
        let flipped = upright.oriented(.down).transformed(by: CGAffineTransform(translationX: 240, y: 160))
        #expect(try distance(flipped, from: upright) > RawImage.suspectPreviewDistance)
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
