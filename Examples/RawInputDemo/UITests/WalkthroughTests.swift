import XCTest

/// Drives the demo through its whole story, the way a person would:
///
///   1. a file both decoders open, switched between them, with and without the shared look;
///   2. a file Apple's decoder rejects, and the fallback developing it.
///
/// It is a smoke test for the app, and the script for the screen recording in the README
/// (`Scripts/record-demo.sh` records the simulator while this runs), which is why it pauses
/// where a viewer needs time to look.
@MainActor
final class WalkthroughTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testWalkthrough() {
        // A file both decoders open: their own outputs differ, the shared look does not.
        open("Sony a9 III")
        expectDecoder("Apple RAW")
        select("Fallback")
        expectDecoder("LibRaw")
        select("Film")
        expectDecoder("LibRaw")
        select("Apple")
        expectDecoder("Apple RAW")
        select("Neutral")
        select("Fallback")
        expectDecoder("LibRaw")
        app.navigationBars.buttons.firstMatch.tap()

        // A file only the fallback opens.
        open("Sigma dp0 Quattro")
        expectDecoder("LibRaw")
        select("Apple")
        XCTAssertTrue(app.staticTexts["Apple's decoder can't open this file"].waitForExistence(timeout: 30))
        look()
        select("Fallback")
        expectDecoder("LibRaw")
        select("Film")
        app.sliders["Exposure"].adjust(toNormalizedSliderPosition: 0.62)
        look()
    }

    private func open(_ title: String) {
        let tile = app.staticTexts[title]
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(title) is in the gallery")
        look()
        tile.tap()
    }

    private func select(_ segment: String) {
        app.buttons[segment].tap()
        look()
    }

    /// Waits for the badge naming the decoder that produced the picture on screen.
    private func expectDecoder(_ prefix: String) {
        let badge = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 60), "decoded by \(prefix)")
        look()
    }

    /// Time for a viewer of the recording to take in what changed.
    private func look() {
        Thread.sleep(forTimeInterval: 1.6)
    }
}
