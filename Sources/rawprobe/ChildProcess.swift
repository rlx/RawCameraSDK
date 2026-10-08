import Foundation

#if os(macOS)
/// Runs this executable again with other arguments and decodes the JSON it prints.
///
/// The probe and the benchmark do their real work in child processes, for two reasons.
/// The files come from the wild, and a decoder that crashes or hangs on one of them should
/// cost one row, not the run. And a fresh process per measurement keeps one decoder's
/// caches and peak memory out of the next one's numbers.
enum ChildProcess {
    enum Outcome<Value> {
        case value(Value)
        case crashed(status: Int32)
        case timedOut
        case notStarted
    }

    static func run<Value: Decodable>(_ arguments: [String], timeout: TimeInterval = 120) -> Outcome<Value> {
        let process = Process()
        let output = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice  // Apple's decoder logs freely
        guard (try? process.run()) != nil else { return .notStarted }

        // A decoder stuck in a loop would otherwise hold the whole run hostage.
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: a child blocked on a full pipe never exits.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = !watchdog.isCancelled && process.terminationReason == .uncaughtSignal
            && process.terminationStatus == SIGTERM
        watchdog.cancel()

        if let value = try? JSONDecoder().decode(Value.self, from: data) { return .value(value) }
        return timedOut ? .timedOut : .crashed(status: process.terminationStatus)
    }
}
#endif
