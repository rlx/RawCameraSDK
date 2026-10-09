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
    /// wrong one it returns an image that renders empty. So for those the registered RAW
    /// types are tried, the camera maker's first, and the first one the decoder reads a
    /// frame size with is kept. The maker's own types are not enough: a Hasselblad Lunar
    /// writes Sony's ARW.
    ///
    /// A trial costs up to 0.15 s and there are about thirty types, so the answer is
    /// remembered per camera model. A caller that knows the type avoids all of it.
    static func memory(_ data: Data, typeHint: String?) -> RawSource {
        if let typeHint { return .data(data, typeHint: typeHint) }
        let detected = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
        if let detected, detected.hasSuffix(Self.rawTypeSuffix) { return .data(data, typeHint: detected) }

        func accepts(_ type: String) -> Bool {
            // A frame size is read from the header, without decoding. With the wrong type
            // there is none.
            guard let size = CIRAWFilter(imageData: data, identifierHint: type)?.nativeSize else { return false }
            return size.width > 0 && size.height > 0
        }
        let header = (try? LibRawFile(.data(data, typeHint: nil))).map { RawInfo($0.info) }
        let camera = header.map { "\($0.make)|\($0.model)" }
        if let camera, let remembered = TypeMemory.shared.type(for: camera) {
            switch remembered {
            case .none: return .data(data, typeHint: detected)
            // Checked, because one model can write more than one container.
            case .some(let type) where accepts(type): return .data(data, typeHint: type)
            case .some: break
            }
        }

        let maker = header?.make.lowercased().split(separator: " ").first.map { "com.\($0)" }
        let makersOwn = Self.rawTypes.filter { type in maker.map(type.hasPrefix) ?? false }
        let accepted = (makersOwn + Self.rawTypes.filter { !makersOwn.contains($0) }).first(where: accepts)
        if let camera { TypeMemory.shared.remember(accepted, for: camera) }
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

/// Remembers, for the life of the process, which type Apple's decoder accepted for a
/// camera model's files when they arrived as untyped bytes, or that it accepted none.
private final class TypeMemory: @unchecked Sendable {
    static let shared = TypeMemory()

    private let lock = NSLock()
    private var types: [String: String?] = [:]  // by "make|model", guarded by `lock`

    /// `nil` if the camera has not been seen, `.some(nil)` if no type was accepted.
    func type(for camera: String) -> String?? { lock.withLock { types[camera] } }
    func remember(_ type: String?, for camera: String) { lock.withLock { types[camera] = type } }
}
