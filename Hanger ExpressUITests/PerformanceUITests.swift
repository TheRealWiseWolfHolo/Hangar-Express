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
    func testGameAccessTilesShowMatchingPackagesAndEmptyState() {
        let app = application()
        app.launch()
        assertOfflineFixture(app)
        let account = app.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        let sc = app.buttons["GameAccess-starCitizen"]
        XCTAssertTrue(sc.waitForExistence(timeout: 15))
        sc.tap()
        XCTAssertTrue(app.staticTexts["Game Packages"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Star Citizen Digital Download"].firstMatch.waitForExistence(timeout: 15))
        let scImage = XCTAttachment(screenshot: app.screenshot())
        scImage.name = "Star Citizen game packages"
        scImage.lifetime = .keepAlways
        add(scImage)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["GameAccess-squadron42"].tap()
        XCTAssertTrue(app.staticTexts["No matching game packages"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Star Citizen Digital Download"].firstMatch.exists)
        let sqImage = XCTAttachment(screenshot: app.screenshot())
        sqImage.name = "Squadron 42 no matching package"
        sqImage.lifetime = .keepAlways
        add(sqImage)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(sc.waitForExistence(timeout: 10))
    }

    @MainActor
    func testCCUCalculatorShowsSimpleRouteAndStepActions() {
        let app = application()
        app.launchEnvironment["HANGAR_CCU_UI_FIXTURE"] = "1"
        app.launch()
        assertOfflineFixture(app)

        app.buttons["Account"].firstMatch.tap()
        let calculator = app.buttons["CCU Calculator"].firstMatch
        for _ in 0..<4 where !calculator.exists {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(calculator.waitForExistence(timeout: 10))
        calculator.tap()
        XCTAssertTrue(app.staticTexts["Select Ships"].firstMatch.waitForExistence(timeout: 15))

        app.staticTexts["Choose source"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Aurora MR")).firstMatch.tap()
        app.staticTexts["Choose destination"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Zeus Mk II MR")).firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Best CCU Chain"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Total Savings"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["New Money"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Source MSRP"].firstMatch.exists)
        let summary = XCTAttachment(screenshot: app.screenshot())
        summary.name = "CCU calculator compact route"
        summary.lifetime = .keepAlways
        add(summary)

        app.buttons["Cost details"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Destination MSRP"].firstMatch.waitForExistence(timeout: 5))
        let firstStep = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "Aurora MR -> Cutlass Black"
        )).firstMatch
        for _ in 0..<3 where !firstStep.exists {
            app.swipeUp()
        }
        XCTAssertTrue(firstStep.waitForExistence(timeout: 5))
        firstStep.tap()
        let exclude = app.buttons["Exclude"].firstMatch
        XCTAssertTrue(exclude.waitForExistence(timeout: 5))
        app.swipeUp()
        for _ in 0..<3 where !exclude.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(exclude.isHittable)
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "CCU calculator expanded step"
        expanded.lifetime = .keepAlways
        add(expanded)
        exclude.tap()
        XCTAssertTrue(app.staticTexts["Excluded CCUs"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Restore"].firstMatch.exists)
    }

    @MainActor
    func testReferralRewardsLaddersAndLegacyViewOnly() throws {
        try verifyReferralRewards(lightMode: false)
    }

    @MainActor
    func testReferralRewardsLightAppearance() throws {
        try verifyReferralRewards(lightMode: true)
    }

    @MainActor
    private func verifyReferralRewards(lightMode: Bool) throws {
        let app = application()
        app.launchEnvironment["HANGAR_REFERRAL_UI_FIXTURE"] = "1"
        app.launchEnvironment["HANGAR_BENCHMARK_LIGHT_MODE"] = lightMode ? "1" : "0"
        for (key, name) in [("current_1", "referral-current-1"), ("current_2", "referral-current-2"), ("current_3", "referral-current-3"), ("current_10", "referral-current-10"), ("legacy_1", "referral-legacy-1"), ("legacy_25", "referral-legacy-25"), ("legacy_200", "referral-legacy-200")] {
            let url = try XCTUnwrap(Bundle(for: PerformanceUITests.self).url(forResource: name, withExtension: "jpg"))
            app.launchEnvironment["HANGAR_REFERRAL_ARTWORK_\(key)"] = try Data(contentsOf: url).base64EncodedString()
        }
        app.launch()
        assertOfflineFixture(app)
        app.buttons["Account"].firstMatch.tap()
        let tool = app.buttons["Referrals, Early Access"].firstMatch
        for _ in 0..<5 {
            if tool.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(tool.waitForExistence(timeout: 15))
        tool.tap()
        XCTAssertTrue(app.staticTexts["9 referrals"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["1 more to the next reward"].exists)
        let firstReward = app.descendants(matching: .any)["referrals.reward.current.1"].firstMatch
        XCTAssertTrue(firstReward.exists)
        XCTAssertTrue(firstReward.label.contains("CDS GCD-Army Medium Armor Set"))
        XCTAssertTrue(firstReward.label.contains("Milestone Reached"))
        let current = XCTAttachment(screenshot: app.screenshot())
        current.name = "New referral ladder — \(lightMode ? "light" : "dark")"
        current.lifetime = .keepAlways
        add(current)
        let legacyButton = app.buttons["referrals.ladder.legacy"]
        let currentButton = app.buttons["referrals.ladder.current"]
        // Hit empty space near each segment's edge, away from the centered text.
        legacyButton.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["View Only"].waitForExistence(timeout: 10))
        let legacyReward = app.descendants(matching: .any)["referrals.reward.legacy.1"].firstMatch
        XCTAssertTrue(legacyReward.exists)
        XCTAssertTrue(legacyReward.label.contains("Badger and Badges"))
        XCTAssertFalse(legacyReward.label.contains("Milestone Reached"))
        XCTAssertFalse(app.staticTexts["9 referrals"].exists)
        XCTAssertFalse(app.staticTexts["Milestone Reached"].exists)
        assertLegacyPictureRatio(app, threshold: 1, title: "Badger and Badges", expected: 285.0 / 120.0)
        let legacy = XCTAttachment(screenshot: app.screenshot())
        legacy.name = "Legacy referral ladder view only — \(lightMode ? "light" : "dark")"
        legacy.lifetime = .keepAlways
        add(legacy)
        for (threshold, title, ratio) in [(25, "Arena Commander Racing Package", 800.0 / 480.0), (200, "Ready For Battle", 560.0 / 392.0)] {
            let titleElement = app.staticTexts[title].firstMatch
            for _ in 0..<4 {
                if titleElement.exists && titleElement.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(titleElement.waitForExistence(timeout: 10))
            assertLegacyPictureRatio(app, threshold: threshold, title: title, expected: ratio)
            let picture = XCTAttachment(screenshot: app.screenshot())
            picture.name = "Legacy picture \(threshold) — \(lightMode ? "light" : "dark")"
            picture.lifetime = .keepAlways
            add(picture)
        }
        for _ in 0..<5 {
            if currentButton.isHittable { break }
            app.swipeDown()
        }
        currentButton.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["9 referrals"].waitForExistence(timeout: 10))
        legacyButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10)).tap()
        XCTAssertTrue(app.staticTexts["View Only"].waitForExistence(timeout: 10))
        currentButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.90)).tap()
        XCTAssertTrue(app.staticTexts["9 referrals"].waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
    }

    @MainActor
    func testAcquiredReferralOpensHangarDetailsAndHandlesMissingAndMultipleMatches() throws {
        let app = application()
        app.launchEnvironment["HANGAR_REFERRAL_UI_FIXTURE"] = "1"
        for (key, name) in [("current_1", "referral-current-1"), ("current_2", "referral-current-2"), ("current_3", "referral-current-3"), ("current_10", "referral-current-10")] {
            let url = try XCTUnwrap(Bundle(for: PerformanceUITests.self).url(forResource: name, withExtension: "jpg"))
            app.launchEnvironment["HANGAR_REFERRAL_ARTWORK_\(key)"] = try Data(contentsOf: url).base64EncodedString()
        }
        app.launch()
        assertOfflineFixture(app)
        app.buttons["Account"].firstMatch.tap()
        let tool = app.buttons["Referrals, Early Access"].firstMatch
        for _ in 0..<5 { if tool.isHittable { break }; app.swipeUp() }
        tool.tap()
        let first = app.descendants(matching: .any)["referrals.reward.current.1"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()
        XCTAssertTrue(app.navigationBars["CDS GCD-Army Medium Armor Set - Referral Reward"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["GCD-Army Helmet"].firstMatch.exists)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "Referral reward using Hangar detail page"
        detail.lifetime = .keepAlways
        add(detail)
        app.navigationBars.buttons["Referrals"].firstMatch.tap()
        let missing = app.descendants(matching: .any)["referrals.reward.current.2"].firstMatch
        for _ in 0..<4 { if missing.isHittable { break }; app.swipeUp() }
        missing.tap()
        XCTAssertTrue(app.alerts["Hangar item unavailable"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        let multiple = app.descendants(matching: .any)["referrals.reward.current.3"].firstMatch
        for _ in 0..<4 { if multiple.isHittable { break }; app.swipeUp() }
        multiple.tap()
        XCTAssertTrue(app.staticTexts["Choose a Hangar item"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Pledge #2"].exists)
        XCTAssertTrue(app.staticTexts["Pledge #3"].exists)
        app.buttons["referrals.match.2"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Gladius Dunlevy Model - Referral Reward"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testStandardReferralToolShowsEarlyAccessPage() {
        let app = application()
        app.launchEnvironment["HANGAR_REFERRAL_UI_FIXTURE"] = "1"
        app.launchEnvironment["HANGAR_REFERRAL_STANDARD_ACCESS"] = "1"
        app.launch()
        assertOfflineFixture(app)
        app.buttons["Account"].firstMatch.tap()
        let tool = app.buttons["Referrals, Early Access"].firstMatch
        for _ in 0..<5 { if tool.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(tool.waitForExistence(timeout: 15))
        let badge = XCTAttachment(screenshot: app.screenshot())
        badge.name = "Referrals tool with Early Access badge"
        badge.lifetime = .keepAlways
        add(badge)
        tool.tap()
        XCTAssertTrue(app.navigationBars["Hangar Express Early Access"].waitForExistence(timeout: 15))
        let release = app.staticTexts["1.2.0"].firstMatch
        for _ in 0..<5 { if release.exists && release.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(release.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Expected release"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "TBD").count, 4)
        XCTAssertFalse(app.staticTexts["Referrals shows your progress and reward pictures for both ladders. Tap reached rewards to view matching Hangar items."].exists)
        XCTAssertTrue(app.staticTexts["Referrals"].exists)
        XCTAssertFalse(app.staticTexts["9 referrals"].exists)
        let page = XCTAttachment(screenshot: app.screenshot())
        page.name = "Early Access page includes Referrals"
        page.lifetime = .keepAlways
        add(page)
    }

    @MainActor
    private func assertLegacyPictureRatio(_ app: XCUIApplication, threshold: Int, title: String, expected: Double) {
        let card = app.descendants(matching: .any)["referrals.reward.legacy.\(threshold)"].firstMatch
        let label = app.staticTexts[title].firstMatch
        let correctProportions = NSPredicate { _, _ in
            guard card.exists, label.exists else { return false }
            // The title has a 16-point top inset below the picture.
            let imageHeight = label.frame.minY - card.frame.minY - 16
            return imageHeight > 0 && abs(Double(card.frame.width / imageHeight) - expected) < 0.03
        }
        let check = XCTNSPredicateExpectation(predicate: correctProportions, object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 10), .completed,
                       "Legacy picture must use its actual proportions, even with stale or missing catalog metadata")
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
