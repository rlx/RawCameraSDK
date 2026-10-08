import CoreImage
import CryptoKit
import Foundation
import Metal
import Testing
import simd
@testable import RawInputKit

/// The ten bundled files that only the fallback opens. Together they are the claim the
/// project makes: Apple's decoder cannot open these, and the fallback can.
///
/// With no sample files at all the suite is skipped, with the command that fetches them;
/// with some but not all, `allTenArePresent` fails, because a partial set is a mistake.
@Suite("Bundled samples", .enabled(if: !Fixtures.samples.isEmpty, "run Examples/RawInputDemo/Scripts/fetch-samples.sh"))
struct SampleTests {
    @Test func allTenArePresent() {
        #expect(Fixtures.samples.count == 10, "run Examples/RawInputDemo/Scripts/fetch-samples.sh")
    }

    @Test(arguments: Fixtures.samples)
    func matchesChecksum(_ sample: Fixtures.Sample) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: sample.url, options: .mappedIfSafe))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == sample.sha256)
    }

    /// If this starts failing after an OS update, Apple has added support for the format.
    /// That is good news: replace the sample and update the README's numbers.
    @Test(arguments: Fixtures.samples)
    func appleRejectsIt(_ sample: Fixtures.Sample) {
        #expect(!RawInput.appleCanDecode(sample.url))
        var options = RawDecodeOptions()
        options.routing = .apple
        #expect(throws: RawError.appleCannotDecode) { try RawInput.open(sample.url, options: options) }
    }

    @Test(arguments: Fixtures.samples)
    func fallbackDevelopsIt(_ sample: Fixtures.Sample) throws {
        let raw = try RawInput.open(sample.url)
        #expect(raw.route == .fallback)
        #expect(!raw.isHalfSize)

        // `info` describes the unrotated frame; the image has the orientation applied.
        let sideways = [.left, .right, .leftMirrored, .rightMirrored].contains(raw.info.orientation)
        let expected = sideways
            ? CGSize(width: raw.info.height, height: raw.info.width)
            : CGSize(width: raw.info.width, height: raw.info.height)
        #expect(raw.image.extent.size == expected)

        // The fallback checks its own colours against the camera's preview. None of the
        // samples should trip it; a regression in levels or white balance would.
        let distance = try #require(raw.previewDistance, "every sample has an embedded preview")
        #expect(distance < RawImage.suspectPreviewDistance)
        #expect(!raw.isColorSuspect)

        let color = centreColor(raw.image)
        #expect(color.min() >= 0)
        #expect(color.max() > 0.001, "the image is black")
        #expect(color.max() <= 1.001, "the fallback clips highlights at 1")
    }

    @Test(arguments: Fixtures.samples)
    func hasMetadataAndPreview(_ sample: Fixtures.Sample) throws {
        let info = try RawInput.info(sample.url)
        #expect(!info.make.isEmpty)
        #expect(info.width > 0 && info.height > 0)
        #expect(info.decoderRoutine != nil)

        let preview = try RawInput.preview(sample.url, maxPixelSize: 512)
        #expect(max(preview.width, preview.height) <= 512)
        #expect(min(preview.width, preview.height) > 32)
    }

    /// Testing whether Apple supports a file costs a good part of a decode, so a "yes" is
    /// kept per camera and mode. Two different cameras must still be tested separately.
    @Test func appleSupportIsRememberedPerKindOfFile() throws {
        try #require(Fixtures.samples.count >= 2)
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [URL] = []
            func append(_ url: URL) { lock.withLock { urls.append(url) } }
            var all: [URL] { lock.withLock { urls } }
        }
        let tested = Log()
        let support = AppleSupport { url in
            tested.append(url)
            return true
        }
        let first = Fixtures.samples[0].url, second = Fixtures.samples[1].url
        #expect(support.canDecode(first))
        #expect(support.canDecode(first))
        #expect(tested.all == [first])
        #expect(support.canDecode(second))
        #expect(tested.all == [first, second])
    }

    /// A "no" may be about one damaged file, not its camera. Remembering it would send every
    /// later file from that camera to the fallback, so each failure is tested afresh.
    @Test func appleRejectionIsNotRemembered() throws {
        let file = try #require(Fixtures.samples.first).url
        final class Answers: @unchecked Sendable {
            private let lock = NSLock()
            private var queue = [false, true]
            func next() -> Bool { lock.withLock { queue.removeFirst() } }
        }
        let answers = Answers()
        let support = AppleSupport { _ in answers.next() }
        #expect(!support.canDecode(file))
        #expect(support.canDecode(file), "the second file of the same kind is tested on its own")
    }

    @Test func reportsEventsForAFallbackDecode() throws {
        let sample = try #require(Fixtures.samples.first)
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [RawEvent] = []
            func append(_ event: RawEvent) { lock.withLock { events.append(event) } }
            var all: [RawEvent] { lock.withLock { events } }
        }
        let log = Log()
        var options = RawDecodeOptions()
        options.eventHandler = { log.append($0) }
        let raw = try RawInput.open(sample.url, options: options)

        // First the routing decision, last the summary; this is what an app would log to
        // learn how often, and for which cameras, Apple's decoder turns files away.
        guard case .appleRejected(let camera, _) = try #require(log.all.first) else {
            Issue.record("expected the rejection first, got \(log.all)")
            return
        }
        #expect(camera == raw.info.camera)
        guard case .opened(_, let route, _, let seconds) = try #require(log.all.last) else {
            Issue.record("expected the summary last, got \(log.all)")
            return
        }
        #expect(route == .fallback && seconds > 0)
    }

    @Test func cancellationStopsAFallbackDecode() throws {
        let sample = try #require(Fixtures.samples.first)
        var options = RawDecodeOptions()
        options.routing = .fallback
        options.isCancelled = { true }
        #expect(throws: RawError.cancelled) { try RawInput.open(sample.url, options: options) }
    }

    /// The frame size comes from the file, so the limit is what stands between a crafted
    /// header and an allocation of whatever it asks for.
    @Test func memoryLimitRefusesAFrameThatWouldExceedIt() throws {
        let sample = try #require(Fixtures.samples.first)
        var options = RawDecodeOptions()
        options.routing = .fallback
        options.fallbackMemoryLimitMB = 1
        #expect(throws: RawError.exceedsMemoryLimit) { try RawInput.open(sample.url, options: options) }
    }

    /// "No limit" has to mean that, on both paths, including the arithmetic.
    @Test(arguments: Fixtures.samples)
    func anUnlimitedMemoryLimitIsAccepted(_ sample: Fixtures.Sample) throws {
        var options = RawDecodeOptions()
        options.fallbackMemoryLimitMB = .max
        #expect(throws: Never.self) { try RawInput.open(sample.url, options: options) }
    }

    @Test(arguments: Fixtures.samples)
    func reportsWhichPathDevelopedIt(_ sample: Fixtures.Sample) throws {
        let raw = try RawInput.open(sample.url)
        #expect(raw.fallbackPath != nil)
        #expect(raw.decoder.contains(raw.fallbackPath == .gpu ? "Metal" : "CPU"))
    }

    /// A grid of thumbnails and a detail view decode at the same time in any real app.
    @Test func decodesInParallel() async throws {
        let urls = Fixtures.samples.map(\.url)
        try #require(!urls.isEmpty)
        let failures = await withTaskGroup(of: Bool.self) { group in
            for url in urls + urls {
                group.addTask {
                    guard let raw = try? RawInput.open(url) else { return true }
                    return centreColor(raw.image).max() <= 0.001 || (try? RawInput.preview(url)) == nil
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(failures == 0)
    }
}

/// The two decoders on a file both can open. They are not expected to look alike (Apple
/// applies a tone curve and the fallback does not), but they must agree on what the picture
/// is: its size, and the colour of things in it.
@Suite("Decoder agreement", .enabled(if: Fixtures.reference != nil, Fixtures.fetchHint))
struct AgreementTests {
    let url = Fixtures.reference!

    private func open(_ url: URL, _ routing: RawDecodeOptions.Routing, halfSizeAbove: Int? = nil) throws -> RawImage {
        var options = RawDecodeOptions()
        options.routing = routing
        if let halfSizeAbove { options.halfSizeAbovePixels = halfSizeAbove }
        return try RawInput.open(url, options: options)
    }

    @Test func automaticPrefersApple() throws {
        #expect(RawInput.appleCanDecode(url))
        #expect(try open(url, .automatic).route == .apple)
    }

    @Test func routesAgreeOnSize() throws {
        let apple = try open(url, .apple), fallback = try open(url, .fallback)
        // Decoders trim sensor borders slightly differently; a few pixels is normal.
        #expect(abs(apple.image.extent.width - fallback.image.extent.width) <= 16)
        #expect(abs(apple.image.extent.height - fallback.image.extent.height) <= 16)
    }

    /// Chromaticity, not brightness: white balance and the colour matrix have to land both
    /// decoders on nearly the same hue even though their tone curves differ.
    @Test func routesAgreeOnColor() throws {
        let apple = chromaticity(centreColor(try open(url, .apple).image))
        let fallback = chromaticity(centreColor(try open(url, .fallback).image))
        #expect(simd_distance(apple, fallback) < 0.05)
    }

    @Test func halfSizeHalvesTheFrameAndKeepsItsColor() throws {
        let full = try open(url, .fallback), half = try open(url, .fallback, halfSizeAbove: 1)
        #expect(half.isHalfSize && !full.isHalfSize)
        #expect(abs(half.image.extent.width * 2 - full.image.extent.width) <= 2)
        #expect(half.info == full.info, "info describes the full-resolution frame either way")
        #expect(simd_distance(chromaticity(centreColor(full.image)), chromaticity(centreColor(half.image))) < 0.01)
    }

    @Test func suggestedExposureBrightensWithoutClippingMuch() throws {
        let raw = try open(url, .fallback)
        #expect(raw.suggestedExposureEV >= 0 && raw.suggestedExposureEV <= 4)
        let shown = centreColor(raw.displayImage())
        #expect(shown.max() >= centreColor(raw.image).max())
        #expect(shown.max() <= 1)
    }

    @Test func displayImageIsClippedOnBothRoutes() throws {
        // Apple's image can carry highlights above 1; `displayImage` promises not to.
        for routing in [RawDecodeOptions.Routing.apple, .fallback] {
            let display = try open(url, routing).displayImage(exposureEV: 6)
            #expect(centreColor(display).max() <= 1.001)
        }
    }

    /// The point of the shared rendering step: scene-linear data from either decoder,
    /// taken through the same look, should be the same picture. Their own outputs are not.
    @Test func sharedRenderingBringsTheRoutesTogether() throws {
        var options = RawDecodeOptions()
        options.routing = .apple
        let appleOwn = try RawInput.open(url, options: options)
        options.appleRendering = .linear
        let appleLinear = try RawInput.open(url, options: options)
        let fallback = try open(url, .fallback)
        #expect(appleOwn.fallbackPath == nil && fallback.fallbackPath == .gpu)
        #expect(!appleOwn.isSceneLinear && appleLinear.isSceneLinear && fallback.isSceneLinear)
        #expect(appleLinear.suggestedExposureEV > 0, "Apple's linear output is measured, like the fallback's")

        let own = simd_distance(centreColor(appleOwn.displayImage()), centreColor(fallback.displayImage()))
        let shared = simd_distance(
            centreColor(appleLinear.rendered(look: .film)), centreColor(fallback.rendered(look: .film)))
        #expect(shared < own, "closer after the shared step than before it")
        #expect(shared < 0.03)
    }

    /// An engine that renders with Metal takes a texture, not a `CIImage`.
    @Test(arguments: [RawDecodeOptions.Routing.apple, .fallback])
    func rendersIntoAMetalTexture(_ routing: RawDecodeOptions.Routing) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var options = RawDecodeOptions.sceneLinear
        options.routing = routing
        let raw = try RawInput.open(url, options: options)
        let texture = try raw.makeTexture(device: device)
        #expect(texture.width == Int(raw.image.extent.width) && texture.height == Int(raw.image.extent.height))
        #expect(texture.pixelFormat == .rgba16Float)

        // Same values as the image, and the right way up: compare the top-left corner.
        let fromTexture = try #require(CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        ])).oriented(.downMirrored)
        let corner = CGRect(x: 0, y: raw.image.extent.height - 64, width: 64, height: 64)
        let expected = centreColor(raw.image.cropped(to: corner))
        let actual = centreColor(fromTexture.cropped(to: corner))
        #expect(simd_distance(expected, actual) < 0.01)
    }

    /// The in-camera crop lives in metadata; the sensor data is the full 3:2 frame. A
    /// decoder that ignores it returns a different picture from the one the photographer took.
    @Test(.enabled(if: Fixtures.cropped != nil, Fixtures.fetchHint))
    func fallbackHonorsInCameraCrop() throws {
        let file = try #require(Fixtures.cropped)
        let apple = try open(file, .apple), fallback = try open(file, .fallback)
        #expect(abs(fallback.image.extent.width - fallback.image.extent.height) <= 2, "the picture is square")
        #expect(abs(apple.image.extent.width - fallback.image.extent.width) <= 2)
        #expect(abs(apple.image.extent.height - fallback.image.extent.height) <= 2)
    }
}
