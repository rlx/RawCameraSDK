// rawprobe: the measuring tools behind the numbers in the README.
//
//   rawprobe <folder> [--json out.json]            which decoder opens each file, and how well
//   rawprobe bench <file>... [--json out.json]     time and memory to a rendered image, per decoder
//   rawprobe compare <file> <out.jpg>              both decoders' output, side by side
//   rawprobe looks <file> <out.jpg>                both decoders through the shared rendering step
//   rawprobe match <file>... [--json out.json]     how alike the routes are, before and after it
//   rawprobe render <file> <out.jpg> [apple|fallback]   develop one file as the demo app shows it
//   rawprobe fuzz <file>... [--iterations N] [--seed S]  decode damaged copies; report crashes
//
// `one`, `bench-one` and `fuzz-one` are the child-process halves of their commands and
// are not meant to be run by hand. Each command lives in its own file; this one only parses
// arguments and dispatches.

import Foundation
import RawInputKit

let usage = """
    usage: rawprobe <folder> [--json out.json]
           rawprobe bench <file>... [--json out.json]
           rawprobe compare <file> <out.jpg>
           rawprobe looks <file> <out.jpg>
           rawprobe match <file>... [--json out.json]
           rawprobe render <file> <out.jpg> [apple|fallback]
           rawprobe fuzz <file>... [--iterations 500] [--seed 1]

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())

/// Removes `<flag> <value>` from the arguments and returns the value.
func takeOption(_ flag: String, from arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count else { fail("\(flag) needs a value\n" + usage) }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path) }

let jsonPath = takeOption("--json", from: &arguments)
let iterations = takeOption("--iterations", from: &arguments).flatMap(Int.init) ?? 500
let seed = takeOption("--seed", from: &arguments).flatMap(UInt64.init) ?? 1
guard let command = arguments.first else { fail(usage) }
let operands = Array(arguments.dropFirst())

do {
    switch (command, operands.count) {
    case ("one", 1):
        FileHandle.standardOutput.write(try JSONEncoder().encode(Probe.measure(fileURL(operands[0]))))
    case ("bench-one", 2):
        let routing: RawDecodeOptions.Routing = operands[0] == "apple" ? .apple : .fallback
        FileHandle.standardOutput.write(try JSONEncoder().encode(Bench.measure(fileURL(operands[1]), routing: routing)))
    case ("compare", 2):
        try Compare.run(input: fileURL(operands[0]), output: fileURL(operands[1]))
    case ("fuzz-one", 1):
        Fuzz.exercise(fileURL(operands[0]))
        FileHandle.standardOutput.write(Data("true".utf8))
    case ("fuzz", 1...):
        #if os(macOS)
        try Fuzz.run(seeds: operands.map(fileURL), iterations: iterations, seed: seed, keepIn: fileURL("fuzz-findings"))
        #else
        fail("fuzz needs child processes and only runs on macOS\n")
        #endif
    case ("looks", 2):
        try Looks.run(input: fileURL(operands[0]), output: fileURL(operands[1]))
    case ("match", 1...):
        try Match.run(files: operands.map(fileURL), jsonPath: jsonPath)
    case ("render", 2), ("render", 3):
        try Render.run(input: fileURL(operands[0]), output: fileURL(operands[1]), route: operands.count == 3 ? operands[2] : nil)
    case ("bench", 1...):
        #if os(macOS)
        try Bench.run(files: operands.map(fileURL), jsonPath: jsonPath)
        #else
        fail("bench needs child processes and only runs on macOS\n")
        #endif
    case (_, 0):
        try Probe.run(folder: fileURL(command), jsonPath: jsonPath)
    default:
        fail(usage)
    }
} catch {
    fail("rawprobe: \(error.localizedDescription)\n")
}
