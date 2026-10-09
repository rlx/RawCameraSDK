import Foundation
import Observation
import PhotosUI
import RawInputKit
import SwiftUI

struct RawItem: Identifiable, Hashable {
    /// How the file reached the app, which decides how it is opened.
    enum Origin: Hashable {
        /// A file on disk, opened by URL.
        case file
        /// Bytes from the photo library, with the type it reported. Opened from memory,
        /// as an app would open them, although the demo keeps a copy on disk between views.
        case photoLibrary(typeIdentifier: String)
    }

    let url: URL
    let title: String
    let detail: String
    var origin = Origin.file

    var id: URL { url }
}

/// One entry of Samples/manifest.json.
private struct Sample: Decodable {
    let file: String
    let camera: String
    let format: String
    /// "shared" marks a file both decoders open. Absent for fallback-only files.
    let group: String?
}

/// The files the gallery shows: the bundled samples and whatever the user imports.
@MainActor
@Observable
final class Library {
    /// Bundled files that Apple's decoder rejects on this OS.
    private(set) var samples: [RawItem] = []
    /// A bundled file both decoders open.
    private(set) var shared: [RawItem] = []
    private(set) var imported: [RawItem] = []
    /// Set when an import fails, for the gallery to show.
    var importFailure: String?

    init() {
        guard let manifest = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([Sample].self, from: data),
              let folder = Bundle.main.resourceURL?.appending(path: "files")
        else { return }
        func items(shared: Bool) -> [RawItem] {
            entries.filter { ($0.group == "shared") == shared }.map {
                RawItem(url: folder.appending(path: $0.file), title: $0.camera, detail: $0.format)
            }
        }
        samples = items(shared: false)
        shared = items(shared: true)
    }

    /// Lists RAW files picked from the photo library.
    ///
    /// The bytes are parked in the temporary folder so a view can map them back into
    /// memory. They are opened as `Data`, with the type the library reported.
    func add(_ picked: [PhotosPickerItem]) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "Imported")
        for (index, item) in picked.enumerated() {
            do {
                let raw = try await PickedRaw.load(item)
                let info = try? RawInput.info(data: raw.data, typeHint: raw.typeIdentifier)
                let copy = try await Develop.store(raw.data, in: root.appending(path: UUID().uuidString))
                imported.append(RawItem(
                    url: copy, title: info?.camera ?? "Photo \(index + 1)", detail: "Photos · \(raw.typeIdentifier)",
                    origin: .photoLibrary(typeIdentifier: raw.typeIdentifier)))
            } catch {
                importFailure = error.localizedDescription
            }
        }
    }

    /// Copies picked files into the app's temporary folder and lists them.
    ///
    /// Access to a picked file ends with the picker's security scope, and Apple's decoder
    /// reads lazily. Each file gets its own folder, so a same-named file never replaces one
    /// a view has open.
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
