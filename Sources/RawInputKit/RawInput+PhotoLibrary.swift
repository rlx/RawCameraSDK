import Foundation
import UniformTypeIdentifiers

extension RawInput {
    /// Of the types a photo-library item offers, the one that is a camera RAW file.
    ///
    /// A photo shot as RAW plus JPEG is one item with both types, and the JPEG is often
    /// listed first. Pass `PHPickerResult.itemProvider.registeredTypeIdentifiers`, the
    /// identifiers of `PhotosPickerItem.supportedContentTypes`, or the
    /// `uniformTypeIdentifier` of each `PHAssetResource`. Request the item's data as the
    /// type returned and pass both to `open(data:typeHint:)`.
    ///
    /// - Returns: `nil` if none of the types is a RAW format the system knows.
    public static func rawTypeIdentifier(among identifiers: [String]) -> String? {
        identifiers.first { UTType($0)?.conforms(to: .rawImage) == true }
    }
}
