import CoreImage

/// The Core Image context RawInputKit uses for its own small renders: the Apple-support
/// probe and preview rotation. It is not used for the caller's rendering.
///
/// One shared context, because creating one is expensive and `CIContext` is thread-safe.
/// Intermediates are not cached: every render here is a one-off, and the cache would only
/// hold on to memory between unrelated files.
enum RenderContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}
