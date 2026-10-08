import CoreGraphics
import Foundation
import ImageIO
import RawShim

/// How the sensor samples colour. It decides which fallback path develops the file.
public enum RawSensorLayout: String, Sendable, Codable {
    /// Full colour at every pixel: linear DNG, merged pixel-shift, reduced-size RAW,
    /// monochrome sensors.
    case fullColor
    /// The usual 2x2 mosaic of red, green and blue. Developed on the GPU.
    case bayer
    /// Fujifilm's 6x6 mosaic.
    case xTrans
    /// Foveon, four-colour mosaics and anything else.
    case other
}

/// What a RAW file says about itself.
public struct RawInfo: Sendable, Equatable {
    public var make: String
    public var model: String
    public var lens: String?

    /// Size of the picture in pixels, before `orientation` is applied.
    ///
    /// From `RawInput.info` this is the sensor's picture area as the file's header describes
    /// it. On a decoded `RawImage` from the fallback route it is the developed frame at full
    /// resolution, which differs for the few sensors LibRaw resamples (Fuji SuperCCD,
    /// non-square pixels). `RawImage.image.extent` is always the image you actually hold.
    public var width: Int
    public var height: Int

    /// The rotation the camera recorded. `RawImage.image` and previews already have it applied.
    public var orientation: CGImagePropertyOrientation

    /// `nil` when the metadata came from ImageIO, which does not expose it.
    public var layout: RawSensorLayout?

    public var iso: Double?
    public var shutterSeconds: Double?
    /// The f-number.
    public var aperture: Double?
    /// In millimetres, as recorded; not a 35 mm equivalent.
    public var focalLength: Double?

    /// When the picture was taken. Cameras record local time with no zone, and LibRaw
    /// interprets it in the zone of the device doing the decoding, so treat this as
    /// approximate to within a day. `nil` when the metadata came from ImageIO.
    public var captureDate: Date?

    public var isDNG: Bool

    /// LibRaw's decoding routine, e.g. "fuji_compressed_load_raw()". It is the most precise
    /// statement of the file's compression mode there is, which makes it the thing to log
    /// when a file misbehaves. `nil` when the metadata came from ImageIO.
    public var decoderRoutine: String?

    public var megapixels: Double { Double(width * height) / 1_000_000 }

    /// Make and model without the repetition some cameras bake in ("Canon Canon EOS R5").
    public var camera: String {
        if make.isEmpty { return model.isEmpty ? "Unknown camera" : model }
        return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
    }

    public init(
        make: String = "", model: String = "", lens: String? = nil, width: Int, height: Int,
        orientation: CGImagePropertyOrientation = .up, layout: RawSensorLayout? = nil, iso: Double? = nil,
        shutterSeconds: Double? = nil, aperture: Double? = nil, focalLength: Double? = nil,
        captureDate: Date? = nil, isDNG: Bool = false, decoderRoutine: String? = nil
    ) {
        self.make = make
        self.model = model
        self.lens = lens
        self.width = width
        self.height = height
        self.orientation = orientation
        self.layout = layout
        self.iso = iso
        self.shutterSeconds = shutterSeconds
        self.aperture = aperture
        self.focalLength = focalLength
        self.captureDate = captureDate
        self.isDNG = isDNG
        self.decoderRoutine = decoderRoutine
    }
}

extension RawInfo {
    /// A placeholder for a file that decodes but whose metadata nothing can read.
    init(size: CGSize) {
        self.init(width: Int(size.width), height: Int(size.height))
    }

    init(_ info: rik_info) {
        func positive(_ value: Float) -> Double? { value > 0 ? Double(value) : nil }
        func nonEmpty(_ string: String) -> String? { string.isEmpty ? nil : string }

        self.init(
            make: Self.string(info.make), model: Self.string(info.model), lens: nonEmpty(Self.string(info.lens)),
            width: Int(info.width), height: Int(info.height), orientation: Self.orientation(flip: info.flip),
            layout: Self.layout(info.cfa_kind), iso: positive(info.iso), shutterSeconds: positive(info.shutter),
            aperture: positive(info.aperture), focalLength: positive(info.focal_length),
            captureDate: info.timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(info.timestamp)) : nil,
            isDNG: info.dng_version != 0, decoderRoutine: nonEmpty(Self.string(info.decoder)))
    }

    /// Metadata from ImageIO, for files LibRaw cannot parse.
    init?(imageSourceAt url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        self.init(
            make: tiff[kCGImagePropertyTIFFMake] as? String ?? "",
            model: tiff[kCGImagePropertyTIFFModel] as? String ?? "",
            lens: exif[kCGImagePropertyExifLensModel] as? String, width: width, height: height,
            orientation: (properties[kCGImagePropertyOrientation] as? UInt32)
                .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first,
            shutterSeconds: exif[kCGImagePropertyExifExposureTime] as? Double,
            aperture: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            isDNG: properties[kCGImagePropertyDNGDictionary] != nil)
    }

    /// Translates a dcraw flip code. Bit 0 mirrors horizontally, bit 1 mirrors vertically and
    /// bit 2 swaps rows with columns; cameras only ever write 0, 3, 5 and 6, but the other
    /// four fall out of the same three bits and cost nothing to get right.
    static func orientation(flip: Int32) -> CGImagePropertyOrientation {
        switch flip {
        case 1: .upMirrored
        case 2: .downMirrored
        case 3: .down
        case 4: .leftMirrored
        case 5: .left   // 90 degrees counter-clockwise
        case 6: .right  // 90 degrees clockwise
        case 7: .rightMirrored
        default: .up
        }
    }

    private static func layout(_ kind: Int32) -> RawSensorLayout {
        switch UInt32(bitPattern: kind) {
        case RIK_CFA_NONE.rawValue: .fullColor
        case RIK_CFA_BAYER.rawValue: .bayer
        case RIK_CFA_XTRANS.rawValue: .xTrans
        default: .other
        }
    }

    /// Reads a fixed-size C `char` array, which Swift imports as a tuple.
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }.trimmingCharacters(in: .whitespaces)
    }
}
