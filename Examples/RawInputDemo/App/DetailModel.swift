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
///   renders. A single loop renders the current exposure, then checks whether it changed
///   meanwhile. However fast the slider moves, the last value is the one left on screen.
@MainActor
@Observable
final class DetailModel {
    private(set) var preview: CGImage?
    private(set) var raw: RawImage?
    private(set) var rendered: CGImage?
    private(set) var failure: String?
    private(set) var memoryMB = 0.0

    /// Stops of exposure added on top of the decoder's suggestion.
    var exposure = 0.0 {
        didSet { if exposure != oldValue { startRendering() } }
    }

    private var generation = 0
    private var isRendering = false
    /// What `rendered` shows, so the loop knows when it has caught up.
    private var shown: (generation: Int, exposure: Double)?

    func loadPreview(_ url: URL) async {
        preview = await Develop.thumbnail(url)
    }

    func decode(_ url: URL, routing: RawDecodeOptions.Routing) async {
        generation += 1
        let mine = generation
        raw = nil
        rendered = nil
        failure = nil
        do {
            let decoded = try await Develop.open(url, routing: routing)
            guard mine == generation else { return }
            raw = decoded
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

        while let raw, shown?.generation != generation || shown?.exposure != exposure {
            let request = (generation: generation, exposure: exposure)
            let image = await Develop.render(raw, exposureEV: request.exposure)
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
