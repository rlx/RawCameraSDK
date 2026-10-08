import Foundation

/// Remembers, for the life of the process, which kinds of file Apple's decoder handles.
///
/// A kind is the camera make and model, LibRaw's decoding routine and the frame size.
/// Only "yes" is remembered, because a "no" can come from a truncated file or a failed
/// render. A damaged file from a supported camera is therefore routed to Apple untested.
/// `RawInput.appleCanDecode` gives a per-file answer.
final class AppleSupport: @unchecked Sendable {
    static let shared = AppleSupport()

    private let lock = NSLock()
    private var supported: Set<String> = []  // guarded by `lock`
    private let test: @Sendable (URL) -> Bool

    /// - Parameter test: the per-file check, replaceable in tests.
    init(test: @escaping @Sendable (URL) -> Bool = AppleRawDecoder.canDecode) {
        self.test = test
    }

    func canDecode(_ url: URL) -> Bool {
        // No readable header means no key.
        guard let info = try? LibRawFile(url).info else { return test(url) }
        let header = RawInfo(info)
        let kind = [
            header.make, header.model, header.decoderRoutine ?? "", "\(header.width)x\(header.height)",
        ].joined(separator: "|")

        if lock.withLock({ supported.contains(kind) }) { return true }
        // The lock is not held across the test, so two threads may both test a new kind.
        guard test(url) else { return false }
        lock.withLock { _ = supported.insert(kind) }
        return true
    }
}
