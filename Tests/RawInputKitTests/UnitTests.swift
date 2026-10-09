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
        // 0.9 / 0.225 is a factor of four, or two stops.
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

    /// A file whose white level equals its black level makes every sample 0/0, which
    /// would crash on conversion to an integer.
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
    /// A flat mid-gray card with a colored patch.
    private func picture(tint: CIColor? = nil) -> CIImage {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: frame)
        let patch = CIImage(color: CIColor(red: 0.7, green: 0.3, blue: 0.2))
            .cropped(to: CGRect(x: 60, y: 40, width: 80, height: 60))
        let composed = patch.composited(over: gray)
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

    /// The camera's preview has its own brightness and contrast, so only hue counts.
    @Test func brightnessAloneIsNotDisagreement() throws {
        // About two thirds of a stop darker. The measure discounts near-black pixels.
        let darker = picture(tint: CIColor(red: 0.8, green: 0.8, blue: 0.8))
        #expect(try distance(darker, from: picture()) < 0.03)
    }

    /// A wrong black level or white balance casts the whole frame.
    @Test func colorCastIsFlagged() throws {
        let pink = picture(tint: CIColor(red: 1, green: 0.55, blue: 0.8))
        #expect(try distance(pink, from: picture()) > RawImage.suspectPreviewDistance)
    }

    @Test func upsideDownPictureIsFlagged() throws {
        // Top half bright red, bottom half blue.
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

    /// Every entry point throws for the file.
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
        // Fixed seed, so a failure is reproducible.
        var state: UInt64 = 0x5EED
        let bytes = (0..<65_536).map { _ -> UInt8 in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        let url = try temporaryFile(Data(bytes), extension: "cr3")
        defer { try? FileManager.default.removeItem(at: url) }
        expectRejected(url)
    }

    /// The header parses, then the sensor data runs out. Decoders differ in whether they
    /// notice, so a decode that succeeds only has to give a non-empty image.
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

/// Choosing the RAW file among the types a photo-library item offers.
@Suite("Photo library types")
struct PhotoLibraryTypeTests {
    /// A RAW plus JPEG pair lists the JPEG first.
    @Test func picksTheRawOfARawPlusJPEGPair() {
        #expect(RawInput.rawTypeIdentifier(among: ["public.jpeg", "com.sony.arw-raw-image"]) == "com.sony.arw-raw-image")
        #expect(RawInput.rawTypeIdentifier(among: ["public.heic", "com.adobe.raw-image"]) == "com.adobe.raw-image")
    }

    /// Every type PhotoKit reported for the sample files, as recorded by the simulator tests.
    @Test(arguments: [
        "com.sony.arw-raw-image", "com.samsung.raw-image", "com.fuji.raw-image", "com.olympus.raw-image",
        "com.panasonic.rw2-raw-image", "com.pentax.raw-image", "com.phaseone.raw-image", "com.canon.cr2-raw-image",
        "com.adobe.raw-image",
    ])
    func recognizesTheTypesPhotoKitReports(_ type: String) {
        #expect(RawInput.rawTypeIdentifier(among: [type]) == type)
    }

    @Test func aPhotoWithoutRawHasNone() {
        #expect(RawInput.rawTypeIdentifier(among: ["public.jpeg", "public.heic", "public.png"]) == nil)
        #expect(RawInput.rawTypeIdentifier(among: []) == nil)
        #expect(RawInput.rawTypeIdentifier(among: ["not a type", "public.tiff"]) == nil)
    }
}

