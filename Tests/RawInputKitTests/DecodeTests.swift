import CoreImage
import CryptoKit
import Foundation
import Metal
import Testing
import simd
@testable import RawInputKit

/// The ten bundled files that only the fallback opens.
/// Skipped when no samples are present. A partial set fails `allTenArePresent`.
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

    /// Fails when an OS update adds Apple support for the format.
    /// Replace the sample and update the README's numbers.
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

        // `info` describes the unrotated frame. The image has the orientation applied.
        let sideways = [.left, .right, .leftMirrored, .rightMirrored].contains(raw.info.orientation)
        let expected = sideways
            ? CGSize(width: raw.info.height, height: raw.info.width)
            : CGSize(width: raw.info.width, height: raw.info.height)
        #expect(raw.image.extent.size == expected)

        // A regression in levels or white balance would trip the preview check.
        let distance = try #require(raw.previewDistance, "every sample has an embedded preview")
        #expect(distance < RawImage.suspectPreviewDistance)
        #expect(!raw.isColorSuspect)

        let color = centerColor(raw.image)
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

    /// A "yes" is cached per camera and mode.
    @Test func appleSupportIsRememberedPerKindOfFile() throws {
        try #require(Fixtures.samples.count >= 2)
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [URL] = []
            func append(_ url: URL) { lock.withLock { urls.append(url) } }
            var all: [URL] { lock.withLock { urls } }
        }
        let tested = Log()
        let support = AppleSupport { source in
            if case .file(let url) = source { tested.append(url) }
            return true
        }
        let first = Fixtures.samples[0].url, second = Fixtures.samples[1].url
        #expect(support.canDecode(.file(first)))
        #expect(support.canDecode(.file(first)))
        #expect(tested.all == [first])
        #expect(support.canDecode(.file(second)))
        #expect(tested.all == [first, second])
    }

    /// The storage mode is part of the kind, so two compression modes of one camera are
    /// tested separately.
    @Test(arguments: Fixtures.samples)
    func storageModeNamesTheDecodingRoutine(_ sample: Fixtures.Sample) throws {
        let file = try LibRawFile(sample.url)
        let routine = try #require(RawInfo(file.info).decoderRoutine)
        #expect(file.storageMode.hasPrefix(routine))
        #expect(file.storageMode.count > routine.count, "compression and bit depth follow the routine")
    }

    /// PhotoKit hands over bytes, not a file.
    @Test(arguments: Fixtures.samples)
    func opensFromMemoryAsFromDisk(_ sample: Fixtures.Sample) throws {
        let data = try Data(contentsOf: sample.url)
        let fromDisk = try RawInput.open(sample.url), fromMemory = try RawInput.open(data: data)
        #expect(fromMemory.route == .fallback && fromMemory.fallbackPath == fromDisk.fallbackPath)
        #expect(fromMemory.info == fromDisk.info)
        #expect(fromMemory.image.extent == fromDisk.image.extent)
        #expect(simd_distance(centerColor(fromMemory.image), centerColor(fromDisk.image)) < 0.001)
        #expect(try RawInput.info(data: data) == RawInput.info(sample.url))
        #expect(try RawInput.preview(data: data, maxPixelSize: 256).width
            == RawInput.preview(sample.url, maxPixelSize: 256).width)
        #expect(!RawInput.appleCanDecode(data: data))
    }

    @Test func emptyDataSaysSo() {
        #expect(throws: RawError.emptyData) { try RawInput.open(data: Data()) }
        #expect(throws: RawError.emptyData) { try RawInput.info(data: Data()) }
    }

    /// The CPU path converts to Rec. 2020 so that 16-bit integers can hold colors outside
    /// sRGB. Colors inside sRGB must come out the same either way.
    @Test func wideGamutOutputKeepsInGamutColor() throws {
        let sample = try #require(Fixtures.samples.first { $0.file.hasSuffix(".raf") })
        func average(wideGamut: Bool) throws -> SIMD3<Double> {
            let file = try LibRawFile(sample.url)
            if wideGamut { file.useWideGamutOutput() }
            try file.unpack()
            return try file.withDeveloped(halfSize: true) { developed in
                let pixels = try #require(developed.pixels)
                var sum = SIMD3<Double>.zero
                let count = Int(developed.width) * Int(developed.height)
                for pixel in 0..<count {
                    sum += SIMD3(Double(pixels[pixel * 3]), Double(pixels[pixel * 3 + 1]), Double(pixels[pixel * 3 + 2]))
                }
                return sum / Double(count) / 65535
            }
        }
        let srgb = try average(wideGamut: false), rec2020 = try average(wideGamut: true)
        // Linear Rec. 2020 to linear sRGB (ITU-R BT.2087).
        let converted = SIMD3(
            1.6605 * rec2020.x - 0.5876 * rec2020.y - 0.0728 * rec2020.z,
            -0.1246 * rec2020.x + 1.1329 * rec2020.y - 0.0083 * rec2020.z,
            -0.0182 * rec2020.x - 0.1006 * rec2020.y + 1.1187 * rec2020.z)
        #expect(simd_distance(srgb, rec2020) > 0.002, "the two outputs are in different primaries")
        #expect(simd_distance(srgb, converted) < 0.004)
    }

    /// A canceled task stops the decode and gets no image.
    @Test func cancelingTheTaskCancelsTheDecode() async throws {
        let file = try #require(Fixtures.samples.first).url
        let task = Task { try await RawInput.open(file) }
        task.cancel()
        await #expect(throws: RawError.cancelled) { try await task.value }
    }

    @Test func asyncOpenMatchesTheBlockingOne() async throws {
        let file = try #require(Fixtures.samples.first).url
        let blocking = try { try RawInput.open(file) }()
        let awaited = try await RawInput.open(data: Data(contentsOf: file))
        #expect(awaited.info == blocking.info && awaited.image.extent == blocking.image.extent)
    }

    /// A "no" may come from one damaged file, so it is never cached.
    @Test func appleRejectionIsNotRemembered() throws {
        let file = try #require(Fixtures.samples.first).url
        final class Answers: @unchecked Sendable {
            private let lock = NSLock()
            private var queue = [false, true]
            func next() -> Bool { lock.withLock { queue.removeFirst() } }
        }
        let answers = Answers()
        let support = AppleSupport { _ in answers.next() }
        #expect(!support.canDecode(.file(file)))
        #expect(support.canDecode(.file(file)), "the second file of the same kind is tested on its own")
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

        // Routing decision first, summary last.
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

    /// The frame size comes from the file, so a crafted header can ask for any allocation.
    @Test func memoryLimitRefusesAFrameThatWouldExceedIt() throws {
        let sample = try #require(Fixtures.samples.first)
        var options = RawDecodeOptions()
        options.routing = .fallback
        options.fallbackMemoryLimitMB = 1
        #expect(throws: RawError.exceedsMemoryLimit) { try RawInput.open(sample.url, options: options) }
    }

    /// `.max` means no limit on both paths, including in the arithmetic.
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

    @Test func decodesInParallel() async throws {
        let urls = Fixtures.samples.map(\.url)
        try #require(!urls.isEmpty)
        let failures = await withTaskGroup(of: Bool.self) { group in
            for url in urls + urls {
                group.addTask {
                    guard let raw = try? await RawInput.open(url) else { return true }
                    return centerColor(raw.image).max() <= 0.001 || (try? RawInput.preview(url)) == nil
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(failures == 0)
    }
}

/// The two decoders on a file both can open. Apple applies a tone curve and the fallback
/// does not, so only size and color are compared.
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
        // Decoders trim sensor borders differently by a few pixels.
        #expect(abs(apple.image.extent.width - fallback.image.extent.width) <= 16)
        #expect(abs(apple.image.extent.height - fallback.image.extent.height) <= 16)
    }

    /// Compares chromaticity because the tone curves differ.
    @Test func routesAgreeOnColor() throws {
        let apple = chromaticity(centerColor(try open(url, .apple).image))
        let fallback = chromaticity(centerColor(try open(url, .fallback).image))
        #expect(simd_distance(apple, fallback) < 0.05)
    }

    @Test func halfSizeHalvesTheFrameAndKeepsItsColor() throws {
        let full = try open(url, .fallback), half = try open(url, .fallback, halfSizeAbove: 1)
        #expect(half.isHalfSize && !full.isHalfSize)
        #expect(abs(half.image.extent.width * 2 - full.image.extent.width) <= 2)
        #expect(half.info == full.info, "info describes the full-resolution frame either way")
        #expect(simd_distance(chromaticity(centerColor(full.image)), chromaticity(centerColor(half.image))) < 0.01)
    }

    @Test func suggestedExposureBrightensWithoutClippingMuch() throws {
        let raw = try open(url, .fallback)
        #expect(raw.suggestedExposureEV >= 0 && raw.suggestedExposureEV <= 4)
        let shown = centerColor(raw.displayImage())
        #expect(shown.max() >= centerColor(raw.image).max())
        #expect(shown.max() <= 1)
    }

    @Test func displayImageIsClippedOnBothRoutes() throws {
        // Apple's image can carry highlights above 1.
        for routing in [RawDecodeOptions.Routing.apple, .fallback] {
            let display = try open(url, routing).displayImage(exposureEV: 6)
            #expect(centerColor(display).max() <= 1.001)
        }
    }

    /// Scene-linear data from either decoder, taken through the same look, should match.
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

        let own = simd_distance(centerColor(appleOwn.displayImage()), centerColor(fallback.displayImage()))
        let shared = simd_distance(
            centerColor(appleLinear.rendered(look: .film)), centerColor(fallback.rendered(look: .film)))
        #expect(shared < own, "closer after the shared step than before it")
        #expect(shared < 0.03)
    }

    /// An edit stores the version it was made with and asks for it again.
    @Test func appleDecoderVersionCanBePinned() throws {
        let first = try open(url, .apple)
        let version = try #require(first.appleDecoderVersion)
        #expect(first.decoder == "Apple RAW \(version)")
        #expect(try open(url, .fallback).appleDecoderVersion == nil)

        var options = RawDecodeOptions()
        options.routing = .apple
        options.appleDecoderVersion = .pinned(version)
        #expect(try RawInput.open(url, options: options).appleDecoderVersion == version)

        options.appleDecoderVersion = .pinned("no such version")
        #expect {
            try RawInput.open(url, options: options)
        } throws: { error in
            guard case RawError.appleDecoderVersionUnavailable(let requested, let available) = error else { return false }
            return requested == "no such version" && available.contains(version)
        }
    }

    @Test func appleRouteOpensFromMemory() throws {
        let data = try Data(contentsOf: url)
        #expect(RawInput.appleCanDecode(data: data))
        let fromMemory = try RawInput.open(data: data), fromDisk = try open(url, .automatic)
        #expect(fromMemory.route == .apple)
        #expect(fromMemory.info == fromDisk.info && fromMemory.image.extent == fromDisk.image.extent)
        #expect(simd_distance(centerColor(fromMemory.image), centerColor(fromDisk.image)) < 0.001)
    }

    @Test func testingEveryFileStillPrefersApple() throws {
        var options = RawDecodeOptions()
        options.appleSupportCheck = .everyFile
        #expect(try RawInput.open(url, options: options).route == .apple)
    }

    /// The GPU path's own texture is handed over when nothing has to change.
    @Test func textureFromTheGPUPathIsNotCopied() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let raw = try open(url, .fallback)
        try #require(raw.fallbackPath == .gpu && raw.info.orientation == .up)
        let first = try raw.makeTexture(device: device), second = try raw.makeTexture(device: device)
        #expect(first === second)
        let wide = try raw.makeTexture(device: device, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        #expect(wide !== first && wide.width == first.width && wide.height == first.height)
    }

    @Test(arguments: [RawDecodeOptions.Routing.apple, .fallback])
    func rendersIntoAMetalTexture(_ routing: RawDecodeOptions.Routing) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var options = RawDecodeOptions.sceneLinear
        options.routing = routing
        let raw = try RawInput.open(url, options: options)
        let texture = try raw.makeTexture(device: device)
        #expect(texture.width == Int(raw.image.extent.width) && texture.height == Int(raw.image.extent.height))
        #expect(texture.pixelFormat == .rgba16Float)

        // The top-left corner checks both the values and which way is up.
        let fromTexture = try #require(CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        ])).oriented(.downMirrored)
        let corner = CGRect(x: 0, y: raw.image.extent.height - 64, width: 64, height: 64)
        let expected = centerColor(raw.image.cropped(to: corner))
        let actual = centerColor(fromTexture.cropped(to: corner))
        #expect(simd_distance(expected, actual) < 0.01)
    }

    /// The in-camera crop lives in metadata. The sensor data is the full 3:2 frame.
    @Test(.enabled(if: Fixtures.cropped != nil, Fixtures.fetchHint))
    func fallbackHonorsInCameraCrop() throws {
        let file = try #require(Fixtures.cropped)
        let apple = try open(file, .apple), fallback = try open(file, .fallback)
        #expect(abs(fallback.image.extent.width - fallback.image.extent.height) <= 2, "the picture is square")
        #expect(abs(apple.image.extent.width - fallback.image.extent.width) <= 2)
        #expect(abs(apple.image.extent.height - fallback.image.extent.height) <= 2)
    }
}
