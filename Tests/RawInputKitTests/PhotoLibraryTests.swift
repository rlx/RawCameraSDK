#if canImport(Photos)
import CoreImage
import Foundation
import Photos
import Testing
import simd
@testable import RawInputKit

/// RAW files saved to the system photo library and read back through PhotoKit, which is
/// how an app receives them: as bytes with a type identifier, not as a file.
///
/// Runs only where it has been given the photo library in advance, so that it never asks
/// for it and never touches a personal library:
///
///     Examples/RawInputDemo/Scripts/photo-library-tests.sh
///
/// runs it in the simulator. Under `swift test` there is no host app to hold the
/// permission, and the suite is skipped.
@Suite("Photo library", .enabled(if: PhotoLibrary.isGranted, "run Examples/RawInputDemo/Scripts/photo-library-tests.sh"), .serialized)
struct PhotoLibraryTests {
    /// The type PhotoKit reports for each sample's format, as measured on iOS 27. These are
    /// the exact identifiers Apple's decoder needs for the formats it cannot tell from TIFF.
    static let reportedTypes = [
        "arw": "com.sony.arw-raw-image", "srw": "com.samsung.raw-image", "raf": "com.fuji.raw-image",
        "orf": "com.olympus.raw-image", "rw2": "com.panasonic.rw2-raw-image", "pef": "com.pentax.raw-image",
        "iiq": "com.phaseone.raw-image", "cr2": "com.canon.cr2-raw-image", "dng": "com.adobe.raw-image",
    ]

    /// Formats the photo library will not store, so they never arrive through PhotoKit.
    static let refusedFormats: Set<String> = ["x3f"]

    @Test(arguments: Fixtures.everySample.filter { !refusedFormats.contains($0.url.pathExtension) })
    func opensWhatPhotoKitHandsOver(_ sample: Fixtures.Sample) async throws {
        let asset = try await PhotoLibrary.asset(holding: sample.url)
        let resources = PHAssetResource.assetResources(for: asset)

        // The type PhotoKit reports must be one the library recognizes as RAW, since that
        // is what picks the RAW resource out of a RAW plus JPEG pair.
        let type = try #require(RawInput.rawTypeIdentifier(among: resources.map(\.uniformTypeIdentifier)))
        #expect(type == Self.reportedTypes[sample.url.pathExtension])
        let resource = try #require(resources.first { $0.uniformTypeIdentifier == type })
        let data = try await PhotoLibrary.data(of: resource)
        #expect(data == (try Data(contentsOf: sample.url)), "the library stores the file byte for byte")

        let fromDisk = try await RawInput.open(sample.url)
        let fromLibrary = try await RawInput.open(data: data, typeHint: type)
        #expect(fromLibrary.route == fromDisk.route, "PhotoKit's type \(type) reaches the same decoder")
        #expect(fromLibrary.info == fromDisk.info)
        #expect(fromLibrary.image.extent == fromDisk.image.extent)
        #expect(simd_distance(centerColor(fromLibrary.image), centerColor(fromDisk.image)) < 0.001)

        // An app that drops the type still gets the same decoder, by trial.
        #expect(try await RawInput.open(data: data).route == fromDisk.route)
        #expect(try RawInput.preview(data: data, typeHint: type, maxPixelSize: 256).width > 32)
    }

    /// Sigma's X3F is not a format Photos accepts. If an OS update changes that, this
    /// fails and the format moves to `reportedTypes`.
    @Test(arguments: Fixtures.everySample.filter { refusedFormats.contains($0.url.pathExtension) })
    func photoLibraryRefusesTheFormat(_ sample: Fixtures.Sample) async {
        await #expect {
            _ = try await PhotoLibrary.asset(holding: sample.url)
        } throws: { error in
            (error as? PHPhotosError)?.code == .invalidResource
        }
    }
}

enum PhotoLibrary {
    /// True in a host app that declares photo library use and already has full access.
    /// Checked in that order: asking about access without the declaration ends the process.
    static var isGranted: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil
            && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// The asset holding a copy of `file`, saving it first if an earlier run has not.
    /// Assets are never deleted: deleting asks the user to confirm, which a test cannot do.
    static func asset(holding file: URL) async throws -> PHAsset {
        let name = file.lastPathComponent
        if let saved = existing(named: name) { return saved }

        let created = Identifier()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            request.addResource(with: .photo, fileURL: file, options: options)
            created.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        let identifier = try #require(created.value)
        return try #require(PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject)
    }

    private static func existing(named name: String) -> PHAsset? {
        var found: PHAsset?
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, stop in
            if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename == name }) {
                found = asset
                stop.pointee = true
            }
        }
        return found
    }

    /// A resource's bytes, as `PHAssetResourceManager` delivers them, in pieces.
    static func data(of resource: PHAssetResource) async throws -> Data {
        let received = Bytes()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { piece in
                received.append(piece)
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: received.all) }
            }
        }
    }

    private final class Identifier: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private final class Bytes: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ piece: Data) { lock.withLock { data.append(piece) } }
        var all: Data { lock.withLock { data } }
    }
}
#endif
