import Foundation

/// How much of the machine decoding may use, and the two limits derived from it.
///
/// A decode holds whole frames: the fallback's CPU path needs about 24 bytes per pixel
/// and a 40 MP file close to 1 GB. Without a bound, importing a folder starts every decode
/// at once and the system ends the app. So decoding as a whole is given a quarter of
/// physical memory, split between a few decodes at a time.
enum DecodeBudget {
    /// Async decodes allowed to run at once: one per 4 GB of memory, between 1 and 4.
    /// Rounded, because a phone sold with 8 GB reports a little less.
    static let concurrentDecodes = min(max(Int((Double(megabytes) / 4096).rounded()), 1), 4)

    /// Working memory one fallback decode may use, so that `concurrentDecodes` of them
    /// fit in a quarter of physical memory.
    static let megabytesPerDecode = megabytes / 4 / concurrentDecodes

    private static var megabytes: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
}

/// Lets a bounded number of async decodes run at once. The rest wait in arrival order.
///
/// A counting semaphore for async code: waiting suspends the task and does not block a
/// thread, and a task canceled while waiting leaves the queue.
final class DecodeGate: @unchecked Sendable {
    static let shared = DecodeGate(limit: DecodeBudget.concurrentDecodes)

    private let lock = NSLock()
    // All guarded by `lock`.
    private var limit: Int
    private var running = 0
    private var waiting: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    /// Tasks canceled before they reached the queue.
    private var cancelledEarly: Set<UInt64> = []
    private var lastID: UInt64 = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var maximum: Int {
        get { lock.withLock { limit } }
        set {
            // Raising the limit lets waiting decodes start.
            let admitted = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                limit = max(1, newValue)
                var admitted: [CheckedContinuation<Void, Error>] = []
                while running < limit, !waiting.isEmpty {
                    running += 1
                    admitted.append(waiting.removeFirst().continuation)
                }
                return admitted
            }
            admitted.forEach { $0.resume() }
        }
    }

    /// Runs `work` once a slot is free.
    ///
    /// - Throws: `RawError.cancelled` if the task is canceled while it waits, without
    ///   running `work`.
    func run<Value>(_ work: () async throws -> Value) async throws -> Value {
        try await enter()
        defer { leave() }
        return try await work()
    }

    private func enter() async throws {
        let id = lock.withLock { () -> UInt64 in
            lastID += 1
            return lastID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case admitted, queued, cancelled }
                let outcome = lock.withLock { () -> Outcome in
                    if cancelledEarly.remove(id) != nil { return .cancelled }
                    if running < limit {
                        running += 1
                        return .admitted
                    }
                    waiting.append((id, continuation))
                    return .queued
                }
                switch outcome {
                case .admitted: continuation.resume()
                case .cancelled: continuation.resume(throwing: RawError.cancelled)
                case .queued: break
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else {
                    // Not queued: either not there yet, or already admitted. If it is not
                    // there yet, `enter` finds this mark. If it was admitted, the mark is
                    // never read, and the decode notices the cancellation itself.
                    cancelledEarly.insert(id)
                    return nil
                }
                return waiting.remove(at: index).continuation
            }
            waiter?.resume(throwing: RawError.cancelled)
        }
        // An admitted task's mark would otherwise stay in the set.
        lock.withLock { _ = cancelledEarly.remove(id) }
    }

    private func leave() {
        // The slot passes straight to the next in line, so `running` does not change.
        let next = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if running <= limit, !waiting.isEmpty { return waiting.removeFirst().continuation }
            running -= 1
            return nil
        }
        next?.resume()
    }
}
