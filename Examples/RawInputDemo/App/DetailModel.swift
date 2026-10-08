import CoreGraphics
import Foundation
import Observation
import RawInputKit

/// State for one open file: the decoded image, what is on screen, and the work in flight.
///
/// Two things arrive asynchronously and out of order: decodes (seconds) and renders (tens
/// of milliseconds, one per slider movement). The rules that keep the screen truthful:
///
/// - **A decode belongs to a generation.** Choosing another decoder starts a new
///   generation, and a result from an older one is dropped on arrival.
/// - **One render at a time, always of the latest request.** Slider movements do not queue
///   renders. A single loop renders the current exposure and look, then checks whether
///   either changed meanwhile. However fast the slider moves, the last value is the one
///   left on screen.
@MainActor
@Observable
final class DetailModel {
    private(set) var preview: CGImage?
    private(set) var raw: RawImage?
    private(set) var rendered: CGImage?
    private(set) var failure: String?
    private(set) var memoryMB = 0.0
    /// How long `RawInput.open` took for the image on screen.
    private(set) var openSeconds = 0.0

    /// Stops of exposure added on top of the decoder's suggestion.
    var exposure = 0.0 {
        didSet { if exposure != oldValue { startRendering() } }
    }

    /// The shared rendering applied after the decoder; `nil` shows the decoder's own output.
    var look: RawLook? {
        didSet { if look != oldValue { startRendering() } }
    }

    /// What a render is asked for, and what `rendered` currently shows.
    private struct Request: Equatable {
        var generation: Int
        var exposure: Double
        var look: RawLook?
    }

    private var generation = 0
    private var isRendering = false
    private var shown: Request?
    private var wanted: Request { Request(generation: generation, exposure: exposure, look: look) }

    func loadPreview(_ url: URL) async {
        preview = await Develop.thumbnail(url)
    }

    /// - Parameter sceneLinear: see `Develop.open`. Changing it means decoding again, because
    ///   it changes what Apple's decoder is asked for.
    func decode(_ url: URL, routing: RawDecodeOptions.Routing, sceneLinear: Bool) async {
        generation += 1
        let mine = generation
        raw = nil
        rendered = nil
        failure = nil
        do {
            let decoded = try await Develop.open(url, routing: routing, sceneLinear: sceneLinear)
            guard mine == generation else { return }
            raw = decoded.image
            openSeconds = decoded.seconds
            await renderUntilCurrent()
            memoryMB = Develop.memoryFootprintMB
        } catch {
            guard mine == generation else { return }
            failure = error.localizedDescription
        }
    }

    private func startRendering() {
        guard raw != nil, !isRendering else { return }
        Task { await renderUntilCurrent() }
    }

    private func renderUntilCurrent() async {
        // If a loop is already running it will notice the change itself.
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }

        while let raw, shown != wanted {
            let request = wanted
            // A look needs scene-linear data. While the decode that will supply it is still
            // on its way, the image in hand is Apple's finished rendering; show it as it is
            // instead of stacking a second tone curve on top.
            let look = raw.isSceneLinear ? request.look : nil
            let image = await Develop.render(raw, look: look, exposureEV: request.exposure)
            // The decoder was switched while this rendered: the image belongs to a file
            // state that is gone. Go round again with whatever is current now.
            guard request.generation == generation else { continue }
            guard let image else {
                failure = RawError.renderFailed(reason: "nothing was drawn").localizedDescription
                return
            }
            rendered = image
            shown = request
        }
    }
}
