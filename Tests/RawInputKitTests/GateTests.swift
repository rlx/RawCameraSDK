import Foundation
import Testing
@testable import RawInputKit

/// The bound on concurrent async decodes, and the memory each may use.
@Suite("Decode budget")
struct GateTests {
    /// Counts how many pieces of work are inside the gate at once.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0, most = 0
        func enter() { lock.withLock { now += 1; most = max(most, now) } }
        func leave() { lock.withLock { now -= 1 } }
        var peak: Int { lock.withLock { most } }
    }

    @Test func neverRunsMoreThanTheLimit() async throws {
        let gate = DecodeGate(limit: 2), counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await gate.run {
                        counter.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(counter.peak == 2)
    }

    @Test func aTaskCanceledWhileWaitingLeavesTheQueue() async throws {
        let gate = DecodeGate(limit: 1)
        let (release, releaseHolder) = AsyncStream<Void>.makeStream()
        let (held, announceHeld) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await gate.run {
                announceHeld.yield()
                for await _ in release { break }
            }
        }
        for await _ in held { break }

        let ran = Counter()
        let waiter = Task { try await gate.run { ran.enter() } }
        waiter.cancel()
        await #expect(throws: RawError.cancelled) { try await waiter.value }
        #expect(ran.peak == 0, "work behind a canceled wait never starts")

        // The slot is still usable afterwards.
        releaseHolder.yield()
        try await holder.value
        try await gate.run { ran.enter() }
        #expect(ran.peak == 1)
    }

    @Test func raisingTheLimitAdmitsWaitingWork() async throws {
        let gate = DecodeGate(limit: 1), counter = Counter()
        let (release, releaseAll) = AsyncStream<Void>.makeStream()
        let (entered, announce) = AsyncStream<Void>.makeStream()
        let tasks = (0..<3).map { _ in
            Task {
                try await gate.run {
                    counter.enter()
                    announce.yield()
                    for await _ in release { break }
                    counter.leave()
                }
            }
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        #expect(counter.peak == 1)
        gate.maximum = 3
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(counter.peak == 3)
        releaseAll.finish()
        for task in tasks { try await task.value }
    }

    @Test func budgetIsAQuarterOfMemorySharedBetweenDecodes() {
        let megabytes = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        #expect((1...4).contains(DecodeBudget.concurrentDecodes))
        #expect(DecodeBudget.concurrentDecodes * DecodeBudget.megabytesPerDecode <= megabytes / 4)
        #expect(RawDecodeOptions().fallbackMemoryLimitMB == DecodeBudget.megabytesPerDecode)
    }

    /// Fujifilm X-T5: 40 MP X-Trans, developed on the CPU path. Measured peak for the
    /// whole process on a phone was 1,271 MB.
    @Test func workingMemoryOfA40MegapixelCPUDecode() {
        let need = WorkingMemory(
            rawWidth: 7872, rawHeight: 5196, width: 7728, height: 5152, planes: 1, isMonochrome: false, halfSize: false)
        #expect(abs(need.megabytes(on: .cpu) - 913) < 5)
        // The GPU path holds the mosaic twice and one RGBA float frame.
        #expect(abs(need.megabytes(on: .gpu) - 460) < 5)
    }

    @Test func halfSizeQuartersTheDevelopmentBuffers() {
        var need = WorkingMemory(
            rawWidth: 11808, rawHeight: 8754, width: 11648, height: 8736, planes: 1, isMonochrome: false, halfSize: false)
        let full = need.megabytes(on: .gpu)
        need.halfSize = true
        let half = need.megabytes(on: .gpu)
        // The sensor data and its texture copy stay. Only the output shrinks.
        #expect(abs((full - half) - Double(11648 * 8736) * 8 * 0.75 / 1_048_576) < 1)
    }
}
