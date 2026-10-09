import CoreTransferable
import Foundation
import PhotosUI
import RawInputKit
import SwiftUI

/// A RAW file picked from the photo library: its bytes and the type the library reports.
///
/// The photo library hands over bytes, not a file, so these go to
/// `RawInput.open(data:typeHint:)`. The type matters: without it Apple's decoder cannot
/// identify several makers' files.
struct PickedRaw: Sendable {
    var data: Data
    var typeIdentifier: String

    enum Failure: LocalizedError {
        case notRaw
        case noData

        var errorDescription: String? {
            switch self {
            case .notRaw: "That photo has no RAW file. Pick one shot in RAW or ProRAW."
            case .noData: "The photo library returned no data for that photo."
            }
        }
    }

    /// Loads the RAW file behind a picked photo.
    ///
    /// A RAW plus JPEG pair is one item offering both types, so the RAW type is chosen from
    /// what the item offers and asked for by name. The picker must be created with
    /// `preferredItemEncoding: .current`, or it may hand back a converted JPEG.
    static func load(_ item: PhotosPickerItem) async throws -> PickedRaw {
        let offered = item.supportedContentTypes.map(\.identifier)
        guard let typeIdentifier = RawInput.rawTypeIdentifier(among: offered) else { throw Failure.notRaw }
        guard let file = try await item.loadTransferable(type: RawFileData.self) else { throw Failure.noData }
        return PickedRaw(data: file.data, typeIdentifier: typeIdentifier)
    }
}

/// Asks the picker for an item's camera RAW representation, as bytes.
private struct RawFileData: Transferable {
    var data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .rawImage) { RawFileData(data: $0) }
    }
}
