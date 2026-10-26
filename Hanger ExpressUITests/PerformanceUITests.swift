import XCTest

final class PerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HANGAR_RUN_UI_BENCHMARKS"] == "1")
        continueAfterFailure = false
    }

    @MainActor
    private func application() -> XCUIApplication {
        let app = XCUIApplication()
        let size = ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_UI_SIZE"] ?? "1000"
        XCTAssertTrue(["100", "1000", "10000"].contains(size), "A supported offline fixture is required")
        app.launchEnvironment["HANGAR_BENCHMARK_UI_SIZE"] = size
        app.launchEnvironment["HANGAR_BENCHMARK_ASCII_KEYBOARD"] = "1"
        return app
    }

    @MainActor
    private func assertOfflineFixture(_ app: XCUIApplication) {
        let size = app.launchEnvironment["HANGAR_BENCHMARK_UI_SIZE"]!
        XCTAssertTrue(app.descendants(matching: .any)["OfflineBenchmark-\(size)"].firstMatch.waitForExistence(timeout: 60))
    }

    @MainActor
    func testProcessLaunch() {
        let app = application()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        // A memory metric may retain a previous PID across launch iterations.
        // Measure memory only in the stable-process tests below.
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            XCTAssertTrue(app.buttons["Fleet"].waitForExistence(timeout: 60))
        }
        assertOfflineFixture(app)
        app.terminate()
    }

    @MainActor
    func testLaunchToReady() {
        let app = application()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart]
        // Keep this separate: XCTest discards companion metrics when a native
        // launch event is missing, even though the automation clock succeeded.
        measure(metrics: [XCTClockMetric()], options: options) {
            app.terminate()
            startMeasuring()
            app.launch()
            assertOfflineFixture(app)
            XCTAssertTrue(app.buttons["Fleet"].waitForExistence(timeout: 60))
        }
        app.terminate()
    }

    @MainActor
    func testResume() {
        let app = application()
        app.launch()
        assertOfflineFixture(app)
        XCTAssertTrue(app.buttons["Fleet"].waitForExistence(timeout: 60))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options) {
            XCUIDevice.shared.press(.home)
            startMeasuring()
            app.activate()
            XCTAssertTrue(app.buttons["Fleet"].waitForExistence(timeout: 30))
        }
    }

    @MainActor
    func testSearchTypingAndClear() {
        let app = application()
        app.launch()
        assertOfflineFixture(app)
        XCTAssertTrue(app.buttons["Buy Back"].waitForExistence(timeout: 60))
        app.buttons["Buy Back"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options) {
            field.tap()
            // Submit separate key events and validate every prefix. Bulk iPad
            // typeText dropped a character; never time an incorrect query.
            // These clocks include automation round trips, not typing latency.
            var prefix = ""
            for character in "ship 12" {
                prefix.append(character)
                field.typeText(String(character))
                XCTAssertEqual(field.value as? String, prefix)
            }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
            let remaining = field.value as? String ?? ""
            XCTAssertTrue(remaining.isEmpty || remaining == "Search buy-back titles and notes")
            let dismiss = app.buttons["Hide Keyboard"]
            if dismiss.exists { dismiss.tap() }
        }
    }
    @MainActor
    func testBulkSearchKeepsTypedQueryAfterKeyboardDismissal() {
        let app = application()
        app.launch()
        assertOfflineFixture(app)
        XCTAssertTrue(app.buttons["Buy Back"].waitForExistence(timeout: 60))
        app.buttons["Buy Back"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("ship 12")
        XCTAssertEqual(field.value as? String, "ship 12")
        let dismiss = app.buttons["Hide Keyboard"]
        if dismiss.exists { dismiss.tap() }
        XCTAssertEqual(field.value as? String, "ship 12")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close Search"].firstMatch.tap()
        let remaining = field.value as? String ?? ""
        XCTAssertTrue(remaining.isEmpty || remaining == "Search buy-back titles and notes")
    }

    @MainActor
    func testHangarLogSearchSurvivesRefreshAndKeyboardDismissal() {
        let app = application()
        app.launch()
        assertOfflineFixture(app)
        let logButton = app.buttons["Log"].firstMatch
        XCTAssertTrue(logButton.waitForExistence(timeout: 30))
        logButton.tap()
        let title = app.staticTexts["Polaris Expedition Pack"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Polaris")
        XCTAssertEqual(field.value as? String, "Polaris")
        app.buttons["Refresh"].firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, "Polaris")
        let dismiss = app.buttons["Hide Keyboard"].firstMatch
        if dismiss.exists { dismiss.tap() }
        XCTAssertEqual(field.value as? String, "Polaris")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close Search"].firstMatch.tap()
        let remaining = field.value as? String ?? ""
        XCTAssertTrue(remaining.isEmpty || remaining == "Search log entries")
        XCTAssertTrue(app.staticTexts["Zeus Mk II MR Patrol Build"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(logButton.waitForExistence(timeout: 10))
    }

    @MainActor
    func testScrolling() {
        let app = application()
        app.launch()
        assertOfflineFixture(app)
        XCTAssertTrue(app.buttons["Buy Back"].waitForExistence(timeout: 60))
        app.buttons["Buy Back"].firstMatch.tap()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

}
