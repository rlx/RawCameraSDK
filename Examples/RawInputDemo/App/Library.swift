import Foundation
import Observation

struct RawItem: Identifiable, Hashable {
    let url: URL
    let title: String
    let detail: String

    var id: URL { url }
}

/// One entry of Samples/manifest.json; the fields the app shows.
private struct Sample: Decodable {
    let file: String
    let camera: String
    let format: String
}

/// The files the gallery shows: the bundled samples and whatever the user imports.
@MainActor
@Observable
final class Library {
    /// Bundled files that Apple's decoder rejects on this OS.
    private(set) var samples: [RawItem] = []
    private(set) var imported: [RawItem] = []
    /// Set when an import fails, for the gallery to show.
    var importFailure: String?

    init() {
        guard let manifest = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([Sample].self, from: data),
              let folder = Bundle.main.resourceURL?.appending(path: "files")
        else { return }
        samples = entries.map {
            RawItem(url: folder.appending(path: $0.file), title: $0.camera, detail: $0.format)
        }
    }

    /// Copies picked files into the app's temporary folder and lists them.
    ///
    /// A copy, because access to a picked file ends when the picker's security scope does,
    /// and Apple's decoder reads its file lazily, long after the pick. Each file gets a
    /// folder of its own: cards are full of files with the same name (`IMG_0001.CR3` from
    /// two shoots), and a file must never be replaced under a view that has it open.
    func add(_ urls: [URL]) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "Imported")
        for url in urls {
            do {
                let copy = try await Develop.importCopy(of: url, into: root.appending(path: UUID().uuidString))
                imported.append(RawItem(
                    url: copy, title: url.deletingPathExtension().lastPathComponent,
                    detail: url.pathExtension.uppercased()))
            } catch {
                importFailure = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}
