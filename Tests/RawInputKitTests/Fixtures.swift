import Foundation
import Testing

/// The RAW files the tests run against.
///
/// None of them are in the repository: they are large, and the archive they come from
/// (raw.pixls.us, CC0) is the source of truth. Fetch them once:
///
///     Examples/RawInputDemo/Scripts/fetch-samples.sh    the ten samples, 270 MB
///     Scripts/corpus.py fetch --only ILCE-9M3 DMC-LX10  the two reference files, 30 MB
///
/// Suites that need a file that is missing are skipped, with a message saying which
/// command fetches it.
///
/// On a physical device there is no repository to read from. The tests then run inside
/// the demo app (see `Scripts/device-tests.sh`) and look in two more places: the app
/// bundle, which already carries the ten samples, and the app's Documents folder, where the
/// script puts the two reference files as `reference.arw` and `cropped.rw2`.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Sample: Decodable, CustomTestStringConvertible {
        let file: String
        let camera: String
        let sha256: String

        var url: URL {
            let inRepository = Fixtures.root.appending(path: "Examples/RawInputDemo/Samples/files/\(file)")
            if FileManager.default.fileExists(atPath: inRepository.path) { return inRepository }
            return Bundle.main.resourceURL?.appending(path: "files/\(file)") ?? inRepository
        }
        var testDescription: String { camera }
    }

    /// The demo app's bundled files. Apple's decoder rejects every one of them, so they
    /// exercise the fallback across its formats: Bayer, X-Trans, Foveon, monochrome,
    /// Phase One, and a DNG.
    static let samples: [Sample] = {
        let manifests = [
            root.appending(path: "Examples/RawInputDemo/Samples/manifest.json"),
            Bundle.main.url(forResource: "manifest", withExtension: "json"),
        ]
        guard let data = manifests.lazy.compactMap({ $0 }).compactMap({ try? Data(contentsOf: $0) }).first,
              let samples = try? JSONDecoder().decode([Sample].self, from: data)
        else { return [] }
        return samples.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }()

    /// An ordinary Bayer file that both decoders open: Sony a9 III, uncompressed.
    static let reference = corpusFile("87a66c6b-Sony_-_ILCE-9M3_-_14bit_(3_2).ARW") ?? document("reference.arw")

    /// A file shot with an in-camera 1:1 crop: Panasonic LX10. The sensor data is 3:2 and
    /// only metadata says the picture is square.
    static let cropped = corpusFile(named: "DMC-LX10_-_1_1") ?? document("cropped.rw2")

    static let fetchHint: Comment = "run Scripts/corpus.py fetch --only ILCE-9M3 DMC-LX10"

    private static var corpus: URL { root.appending(path: "Tests/Corpus") }

    private static func document(_ name: String) -> URL? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appending(path: name)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static func corpusFile(_ name: String) -> URL? {
        let url = corpus.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func corpusFile(named fragment: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: corpus.path)) ?? []
        return names.first { $0.contains(fragment) }.map { corpus.appending(path: $0) }
    }
}
