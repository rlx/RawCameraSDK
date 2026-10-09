import XCTest

/// Imports from the system photo picker, as a user would.
///
/// Needs the sample RAW files in the simulator's photo library, which
/// `Scripts/photo-library-tests.sh` arranges by running the hosted PhotoKit tests first.
/// The library also holds the simulator's stock photos, which are not RAW.
@MainActor
final class PhotoImportTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Picks every photo in the library. The RAW files are listed with the type the photo
    /// library reported and open from their bytes. The stock photos are refused with a
    /// reason.
    func testPickedPhotosAreOpenedFromTheirBytes() throws {
        app.buttons["Photos"].tap()
        // The picker is another process's view shown inside the app.
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 30), "the picker shows the library")
        XCTAssertGreaterThan(
            cells.count, 6, "run Scripts/photo-library-tests.sh: the library holds only the simulator's stock photos")
        for cell in cells.allElementsBoundByIndex where cell.isHittable { cell.tap() }
        // Named "Add" or "Done" depending on the OS version.
        let confirm = app.buttons["Add"].exists ? app.buttons["Add"] : app.buttons["Done"]
        confirm.tap()

        // A photo with no RAW file is refused, and says why.
        let alert = app.alerts["Couldn't import"]
        XCTAssertTrue(alert.waitForExistence(timeout: 120))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "no RAW file")).firstMatch.exists)
        while alert.exists {
            alert.buttons["OK"].tap()
            _ = alert.waitForNonExistence(timeout: 2)
        }

        // The Sony file is the telling one: Apple's decoder opens it from bytes only when
        // it is given the type.
        XCTAssertTrue(app.staticTexts["Imported"].waitForExistence(timeout: 120))
        let sony = app.staticTexts["Photos · com.sony.arw-raw-image"]
        XCTAssertTrue(sony.waitForExistence(timeout: 120), "listed with the type the photo library reported")
        XCTAssertTrue(app.staticTexts["Photos · com.samsung.raw-image"].firstMatch.exists)
        sony.tap()

        expectDecoder("Apple RAW")
        app.buttons["Fallback"].tap()
        expectDecoder("LibRaw")
    }

    private func expectDecoder(_ prefix: String) {
        let badge = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 60), "developed by \(prefix) from the photo's bytes")
    }
}
