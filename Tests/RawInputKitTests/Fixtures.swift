import Foundation
import Testing

/// The RAW files the tests run against.
///
/// None of them are in the repository: they are large, and the archive they come from
/// (raw.pixls.us, CC0) is the source of truth. Fetch them once:
///
///     Examples/RawInputDemo/Scripts/fetch-samples.sh    the demo's eleven files, 285 MB
///     Scripts/corpus.py fetch --only DMC-LX10           one more, for the crop test, 20 MB
///
/// Suites that need a file that is missing are skipped, with a message saying which
/// command fetches it.
///
/// On a physical device there is no repository to read from. The tests then run inside
/// the demo app (see `Scripts/device-tests.sh`) and look in two more places: the app
/// bundle, which already carries the demo's files, and the app's Documents folder, where
/// the script puts the crop-test file as `cropped.rw2`.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Sample: Decodable, CustomTestStringConvertible {
        let file: String
        let camera: String
        let sha256: String
        /// "shared" for the file both decoders open; absent for the ten only the fallback does.
        let group: String?

        var url: URL {
            let inRepository = Fixtures.root.appending(path: "Examples/RawInputDemo/Samples/files/\(file)")
            if FileManager.default.fileExists(atPath: inRepository.path) { return inRepository }
            return Bundle.main.resourceURL?.appending(path: "files/\(file)") ?? inRepository
        }
        var testDescription: String { camera }
    }

    /// The ten bundled files Apple's decoder rejects. They exercise the fallback across its
    /// formats: Bayer, X-Trans, Foveon, monochrome, Phase One, and a DNG.
    static let samples = bundled.filter { $0.group != "shared" }

    /// The bundled file both decoders open, an ordinary Bayer file: Sony a9 III.
    static let reference = bundled.first { $0.group == "shared" }?.url

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

    /// A file shot with an in-camera 1:1 crop: Panasonic LX10. The sensor data is 3:2 and
    /// only metadata says the picture is square.
    static let cropped = corpusFile(named: "DMC-LX10_-_1_1") ?? document("cropped.rw2")

    static let fetchHint: Comment = "run fetch-samples.sh, and Scripts/corpus.py fetch --only DMC-LX10"

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
