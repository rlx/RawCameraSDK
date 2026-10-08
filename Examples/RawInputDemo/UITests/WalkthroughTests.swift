import XCTest

/// Drives the demo through two files: one both decoders open, switched between them with
/// and without the shared look, and one only the fallback opens.
///
/// Also the script for the README's screen recording (`Scripts/record-demo.sh`), so it
/// pauses where a viewer needs time to look.
@MainActor
final class WalkthroughTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testWalkthrough() {
        // A file both decoders open.
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
