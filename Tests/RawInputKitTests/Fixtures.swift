import Foundation
import Testing

/// The RAW files the tests run against. They are not in the repository.
/// Fetch them once from raw.pixls.us (CC0):
///
///     Examples/RawInputDemo/Scripts/fetch-samples.sh    the demo's eleven files, 285 MB
///     Scripts/corpus.py fetch --only DMC-LX10_-_1_1     one more, for the crop test, 22 MB
///
/// Suites that need a missing file are skipped.
///
/// On a device the tests run inside the demo app (see `Scripts/device-tests.sh`). They
/// also look in the app bundle and in the app's Documents folder, where the script puts
/// the crop-test file as `cropped.rw2`.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Sample: Decodable, CustomTestStringConvertible {
        let file: String
        let camera: String
        let sha256: String
        /// "shared" for the file both decoders open. Absent for the other ten.
        let group: String?

        var url: URL {
            let inRepository = Fixtures.root.appending(path: "Examples/RawInputDemo/Samples/files/\(file)")
            if FileManager.default.fileExists(atPath: inRepository.path) { return inRepository }
            return Bundle.main.resourceURL?.appending(path: "files/\(file)") ?? inRepository
        }
        var testDescription: String { camera }
    }

    /// The ten bundled files Apple's decoder rejects: Bayer, X-Trans, Foveon, monochrome,
    /// Phase One, and a DNG.
    static let samples = bundled.filter { $0.group != "shared" }

    /// The bundled file both decoders open: Sony a9 III, Bayer.
    static let reference = bundled.first { $0.group == "shared" }?.url

    /// All eleven bundled files.
    static var everySample: [Sample] { bundled }

    private static let bundled: [Sample] = {
        let manifests = [
            root.appending(path: "Examples/RawInputDemo/Samples/manifest.json"),
            Bundle.main.url(forResource: "manifest", withExtension: "json"),
        ]
        guard let data = manifests.lazy.compactMap({ $0 }).compactMap({ try? Data(contentsOf: $0) }).first,
              let samples = try? JSONDecoder().decode([Sample].self, from: data)
        else { return [] }
        return samples.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }()

    /// Panasonic LX10 with an in-camera 1:1 crop. The sensor data is 3:2 and only metadata
    /// says the picture is square.
    static let cropped = corpusFile(named: "DMC-LX10_-_1_1") ?? document("cropped.rw2")

    /// Hasselblad Lunar, a rebadged Sony: Hasselblad in the metadata, Sony's ARW container.
    static let rebadged = corpusFile(named: "HASSELBLAD_-_Lunar")

    static let fetchHint: Comment = "run fetch-samples.sh, and Scripts/corpus.py fetch --only DMC-LX10_-_1_1"

    private static var corpus: URL { root.appending(path: "Tests/Corpus") }

    private static func document(_ name: String) -> URL? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appending(path: name)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static func corpusFile(named fragment: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: corpus.path)) ?? []
        return names.first { $0.contains(fragment) }.map { corpus.appending(path: $0) }
    }
}
