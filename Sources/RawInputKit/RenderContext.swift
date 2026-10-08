import CoreImage

/// The shared Core Image context for RawInputKit's own small renders. Intermediates are
/// not cached, since every render here is a one-off.
enum RenderContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}
