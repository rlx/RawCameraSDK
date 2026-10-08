import Foundation

/// Remembers, for the life of the process, whether Apple's decoder handles each kind of file.
///
/// Testing a file means having Apple's engine decompress most of it (see
/// `AppleRawDecoder.canDecode`), which would nearly double the cost of opening every file
/// Apple supports. But support is a property of the camera and its recording mode, not of
/// the individual picture, and photographers open files in runs from the same camera. So
/// the first file of each kind is tested and the rest reuse the answer.
///
/// "Kind" is the camera model, LibRaw's decoding routine (which names the compression
/// scheme) and the frame size (which separates crop and reduced-size modes). These are
/// exactly the things that decide whether Apple's engine supports a file.
///
/// What this gives up: a damaged file from a supported camera is routed to Apple on the
/// strength of its siblings and may render incompletely. The per-file test never fully
/// protected against that anyway, since it reads one small region. Callers who need a
/// per-file answer have `RawInput.appleCanDecode`.
///
/// Nothing is persisted: an OS update can change the answers, and a process restart is a
/// cheap way to never be wrong about that.
final class AppleSupport: @unchecked Sendable {
    static let shared = AppleSupport()

    private let lock = NSLock()
    private var decisions: [String: Bool] = [:]  // guarded by `lock`
    private let test: @Sendable (URL) -> Bool

    /// - Parameter test: the per-file check; replaceable so tests can count how often it runs.
    init(test: @escaping @Sendable (URL) -> Bool = AppleRawDecoder.canDecode) {
        self.test = test
    }

    func canDecode(_ url: URL) -> Bool {
        // Without a readable header there is nothing to key on; test the file directly.
        guard let info = try? LibRawFile(url).info else { return test(url) }
        let header = RawInfo(info)
        let kind = [
            header.make, header.model, header.decoderRoutine ?? "", "\(header.width)x\(header.height)",
        ].joined(separator: "|")

        if let known = lock.withLock({ decisions[kind] }) { return known }
        // Two threads meeting a new kind at once both test it and store the same answer;
        // holding the lock across a decode to prevent that would serialise every open.
        let answer = test(url)
        lock.withLock { decisions[kind] = answer }
        return answer
    }
}
