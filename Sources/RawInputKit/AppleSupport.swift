import Foundation

/// Remembers, for the life of the process, which kinds of file Apple's decoder handles.
///
/// A kind is the camera make and model, the frame size and the storage mode: decoding
/// routine, compression code, bit depth and the makers' own compression fields. Support
/// differs between modes of one camera, such as lossless and lossy compression, so the
/// routine alone is not enough.
///
/// Only "yes" is remembered, because a "no" can come from a truncated file or a failed
/// render. A damaged file from a supported camera is therefore routed to Apple untested.
/// `RawDecodeOptions.AppleSupportCheck.everyFile` tests each file instead.
final class AppleSupport: @unchecked Sendable {
    static let shared = AppleSupport()

    private let lock = NSLock()
    private var supported: Set<String> = []  // guarded by `lock`
    private let test: @Sendable (RawSource) -> Bool

    /// - Parameter test: the per-file check, replaceable in tests.
    init(test: @escaping @Sendable (RawSource) -> Bool = AppleRawDecoder.canDecode) {
        self.test = test
    }

    func canDecode(_ source: RawSource) -> Bool {
        // No readable header means no key.
        guard let file = try? LibRawFile(source) else { return test(source) }
        let header = RawInfo(file.info)
        let kind = [header.make, header.model, "\(header.width)x\(header.height)", file.storageMode]
            .joined(separator: "|")

        if lock.withLock({ supported.contains(kind) }) { return true }
        // The lock is not held across the test, so two threads may both test a new kind.
        guard test(source) else { return false }
        lock.withLock { _ = supported.insert(kind) }
        return true
    }
}
