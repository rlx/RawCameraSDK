// rawprobe: the measuring tools behind the numbers in the README.
//
//   rawprobe <folder> [--json out.json]            which decoder opens each file, and how well
//   rawprobe bench <file>... [--json out.json]     time and memory to a rendered image, per decoder
//   rawprobe compare <file> <out.jpg>              both decoders' output, side by side
//   rawprobe render <file> <out.jpg> [apple|fallback]   develop one file as the demo app shows it
//
// `one` and `bench-one` are the child-process halves of the first two commands and are
// not meant to be run by hand. Each command lives in its own file; this one only parses
// arguments and dispatches.

import Foundation
import RawInputKit

let usage = """
    usage: rawprobe <folder> [--json out.json]
           rawprobe bench <file>... [--json out.json]
           rawprobe compare <file> <out.jpg>
           rawprobe render <file> <out.jpg> [apple|fallback]

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())

/// Removes `--json <path>` from the arguments and returns the path.
func takeJSONPath(from arguments: inout [String]) -> String? {
    guard let flag = arguments.firstIndex(of: "--json") else { return nil }
    guard flag + 1 < arguments.count else { fail("--json needs a path\n" + usage) }
    let path = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
    return path
}

func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path) }

let jsonPath = takeJSONPath(from: &arguments)
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
