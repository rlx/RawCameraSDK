// Converts a screen recording into a compact animated GIF, using only system frameworks.
//
//     swift movie-to-gif.swift <movie> <out.gif> [frames per second] [width in pixels]
//
// GitHub shows a GIF inline in a README; it does not do that for a video file in the
// repository. Five frames a second at 300 pixels wide keeps a one-minute walkthrough to a
// few megabytes while leaving every state readable.
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

for index in 0..<frameCount {
    let time = CMTime(seconds: Double(index) / framesPerSecond, preferredTimescale: 600)
    let frame = try await generator.image(at: time).image
    CGImageDestinationAddImage(destination, frame, frameProperties)
}
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write the GIF\n".utf8))
    exit(1)
}
print("\(frameCount) frames, \(Int(duration)) s -> \(arguments[2])")
