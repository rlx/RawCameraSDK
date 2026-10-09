// Converts a screen recording into a compact animated GIF, using only system frameworks.
//
//     swift movie-to-gif.swift <movie> <out.gif> [frames per second] [width in pixels]
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: movie-to-gif.swift <movie> <out.gif> [fps] [width]\n".utf8))
    exit(2)
}
let framesPerSecond = arguments.count > 3 ? Double(arguments[3]) ?? 5 : 5
let width = arguments.count > 4 ? Double(arguments[4]) ?? 300 : 300

let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))
let duration = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: width, height: width * 4)
generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

let frameCount = Int(duration * framesPerSecond)
guard frameCount > 0,
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[2]) as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
else {
    FileHandle.standardError.write(Data("could not read the movie or create the GIF\n".utf8))
    exit(1)
}
CGImageDestinationSetProperties(destination, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)
let frameProperties = [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / framesPerSecond],
] as CFDictionary

/// A frame reduced to a 16 by 16 grid of gray levels, for telling two frames apart.
func signature(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 256)
    let context = CGContext(
        data: &pixels, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
    return pixels
}

// The recording starts before the app does. Frames are dropped until the picture differs
// from the first one, so the GIF opens on the app and not on the simulator's home screen.
var homeScreen: [UInt8]?
var written = 0
for index in 0..<frameCount {
    let time = CMTime(seconds: Double(index) / framesPerSecond, preferredTimescale: 600)
    let frame = try await generator.image(at: time).image
    if written == 0 {
        let current = signature(frame)
        guard let first = homeScreen else {
            homeScreen = current
            continue
        }
        let difference = zip(first, current).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / 256
        if difference < 24 { continue }
    }
    CGImageDestinationAddImage(destination, frame, frameProperties)
    written += 1
}
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write the GIF\n".utf8))
    exit(1)
}
print("\(written) of \(frameCount) frames, \(Int(duration)) s -> \(arguments[2])")
