import CoreImage
import Foundation
import ImageIO

/// Where a RAW file's bytes are: on disk, or already in memory (as PhotoKit delivers them).
enum RawSource: Sendable {
    case file(URL)
    /// `typeHint` is a uniform type identifier such as "com.sony.arw-raw-image". Build
    /// this case with `memory(_:typeHint:)`, which fills in a missing type.
    case data(Data, typeHint: String?)

    func makeAppleFilter() -> CIRAWFilter? {
        switch self {
        case .file(let url): CIRAWFilter(imageURL: url)
        case .data(let data, let typeHint): CIRAWFilter(imageData: data, identifierHint: typeHint)
        }
    }

    /// A source for bytes in memory, with the type worked out when the caller gave none.
    ///
    /// Apple's decoder needs the exact type for the TIFF-based formats ImageIO cannot tell
    /// from plain TIFF: Sony ARW, Samsung SRW, Pentax PEF, Nikon NRW. Given no type or the
    /// wrong one it returns an image that renders empty. So for those the camera maker's
    /// registered RAW types are tried in turn, and the first one the decoder accepts is
    /// kept. A caller that knows the type saves this work by passing it.
    static func memory(_ data: Data, typeHint: String?) -> RawSource {
        if let typeHint { return .data(data, typeHint: typeHint) }
        let detected = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
        if let detected, detected.hasSuffix(Self.rawTypeSuffix) { return .data(data, typeHint: detected) }

        guard let file = try? LibRawFile(.data(data, typeHint: nil)),
              let maker = RawInfo(file.info).make.lowercased().split(separator: " ").first
        else { return .data(data, typeHint: detected) }
        let accepted = Self.rawTypes.filter { $0.hasPrefix("com.\(maker).") }.first { type in
            guard let image = CIRAWFilter(imageData: data, identifierHint: type)?.outputImage else { return false }
            return !image.extent.isEmpty && !image.extent.isInfinite
        }
        return .data(data, typeHint: accepted ?? detected)
    }

    private static let rawTypeSuffix = "raw-image"

    /// The RAW types registered with ImageIO, such as "com.sony.arw-raw-image".
    private static let rawTypes = ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        .filter { $0.hasSuffix(rawTypeSuffix) }.sorted()

    func makeImageSource() -> CGImageSource? {
        switch self {
        case .file(let url):
            return CGImageSourceCreateWithURL(url as CFURL, nil)
        case .data(let data, let typeHint):
            let options = typeHint.map { [kCGImageSourceTypeIdentifierHint: $0] as CFDictionary }
            return CGImageSourceCreateWithData(data as CFData, options)
        }
    }

    /// Throws `RawError.fileUnreadable` for a file that is missing or not readable, and for
    /// empty data.
    func checkReadable() throws {
        switch self {
        case .file(let url):
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw RawError.fileUnreadable(url) }
        case .data(let data, _):
            guard !data.isEmpty else { throw RawError.emptyData }
        }
    }
}
