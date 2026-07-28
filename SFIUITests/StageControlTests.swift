import XCTest

@MainActor
final class StageControlTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testStartService() {
        let startButton = app.buttons["Start"].firstMatch
        XCTAssertTrue(startButton.waitForExistence(timeout: 20), "Start button did not appear")
        startButton.tap()

        let stopButton = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stopButton.waitForExistence(timeout: 30), "VPN did not reach started state")
    }
}
