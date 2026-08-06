import Darwin
import Network
import XCTest

@MainActor
final class DeviceScenarioTests: XCTestCase {
    private var scenario: DeviceScenario!
    private var apps: [String: XCUIApplication] = [:]
    private var shouldRestoreWiFi = false
    private var failedSections = Set<String>()
    private var leaveVPNRunning = false
    private var scenarioCompleted = false

    override func setUpWithError() throws {
        continueAfterFailure = true
        scenario = try DeviceScenario.load()
        leaveVPNRunning = ProcessInfo.processInfo.environment["WLT_DEVICE_LEAVE_RUNNING"] == "1"
        apps["vpn"] = XCUIApplication()
        for (name, bundleIdentifier) in scenario.apps where name != "vpn" {
            apps[name] = XCUIApplication(bundleIdentifier: bundleIdentifier)
        }
        apps["vpn"]?.launchEnvironment["WLT_DEVICE_SCENARIO"] = "1"
    }

    override func tearDownWithError() throws {
        defer {
            apps.removeAll()
            failedSections.removeAll()
            scenarioCompleted = false
            scenario = nil
        }

        // Cleanup may need to launch a freshly signed development build. Restore
        // unrestricted Wi-Fi first so iOS can complete its online trust check.
        restoreWiFiIfNeeded()

        if leaveVPNRunning, scenarioCompleted {
            apps["safari"]?.terminate()
            guard let vpnApp = apps["vpn"] else { return }
            vpnApp.activate()
            guard vpnApp.staticTexts["Started"].firstMatch.waitForExistence(timeout: 30) else {
                attachScreenshot(named: "vpn-leave-running-not-started")
                XCTFail("VPN was not running when the persistent scenario completed")
                return
            }
            attachScreenshot(named: "vpn-left-running")
            return
        }

        for (index, step) in (scenario?.cleanupSteps ?? []).enumerated() {
            do {
                try execute(step)
            } catch {
                attachScreenshot(named: String(format: "cleanup-failure-%03d", index + 1))
                XCTFail("Cleanup step \(index + 1) failed: \(step.summary): \(error)")
            }
        }

        guard let vpnApp = apps["vpn"] else { return }
        vpnApp.activate()
        guard vpnApp.staticTexts["Started"].firstMatch.waitForExistence(timeout: 3) else { return }

        // MainView exports the live command-client log when it returns to the
        // foreground during a device scenario. Force a real scene transition
        // and leave enough time for command IPC plus the atomic file write;
        // otherwise the host runner may copy a stale log from an earlier run.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        vpnApp.activate()
        guard vpnApp.wait(for: .runningForeground, timeout: 10) else { return }
        Thread.sleep(forTimeInterval: 5)

        // A full WLT reconnect can complete while the app is already active.
        // Trigger one more transition after the settle window so MainView
        // exports the post-reconnect counters instead of the pre-reconnect log.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        vpnApp.activate()
        guard vpnApp.wait(for: .runningForeground, timeout: 10) else { return }
        Thread.sleep(forTimeInterval: 5)

        let toggle = vpnApp.descendants(matching: .any).matching(identifier: "wlt.connection.toggle").firstMatch
        for _ in 0 ..< 3 where !toggle.isHittable {
            let backButton = vpnApp.navigationBars.buttons.firstMatch
            if backButton.exists, backButton.isHittable {
                backButton.tap()
            } else {
                // Groups and Connections are presented as draggable sheets on
                // iPhone, so they have no navigation-bar back button.
                let sheetGrabber = vpnApp.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)
                )
                let sheetBottom = vpnApp.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)
                )
                sheetGrabber.press(
                    forDuration: 0.05,
                    thenDragTo: sheetBottom,
                    withVelocity: .fast,
                    thenHoldForDuration: 0
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard toggle.waitForExistence(timeout: 3) else {
            attachScreenshot(named: "vpn-teardown-toggle-not-hittable")
            XCTFail("Cleanup could not reach the VPN stop button")
            return
        }
        if toggle.isHittable {
            toggle.tap()
        } else {
            vpnApp.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.875)).tap()
        }
        guard vpnApp.staticTexts["Stopped"].firstMatch.waitForExistence(timeout: 30) else {
            attachScreenshot(named: "vpn-teardown-stop-timeout")
            XCTFail("Cleanup could not stop the VPN")
            return
        }
        attachScreenshot(named: "vpn-teardown-stopped")
    }

    func testScenario() throws {
        try XCTContext.runActivity(named: scenario.name) { _ in
            for (index, step) in scenario.steps.enumerated() {
                if let section = step.section, failedSections.contains(section) {
                    continue
                }
                do {
                    try XCTContext.runActivity(named: String(format: "%03d %@", index + 1, step.summary)) { _ in
                        try execute(step)
                    }
                } catch {
                    attachScreenshot(named: String(format: "failure-%03d", index + 1))
                    XCTFail("Step \(index + 1) failed: \(step.summary): \(error)")
                    if let section = step.section {
                        failedSections.insert(section)
                    }
                    if step.fatal || !scenario.continueOnFailure {
                        throw error
                    }
                }
            }
        }
        scenarioCompleted = true
    }

    func testCrossAppProof() {
        let vpnApp = application(named: "vpn")
        vpnApp.launch()
        XCTAssertTrue(vpnApp.wait(for: .runningForeground, timeout: 20))
        attachScreenshot(named: "01-vpn")

        let safariApp = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safariApp.launch()
        XCTAssertTrue(safariApp.wait(for: .runningForeground, timeout: 20))
        attachScreenshot(named: "02-safari")

        vpnApp.activate()
        XCTAssertTrue(vpnApp.wait(for: .runningForeground, timeout: 20))
        attachScreenshot(named: "03-vpn-return")
    }

    private func execute(_ step: DeviceScenario.Step) throws {
        let app = application(named: step.app ?? "vpn")
        let timeout = step.timeout ?? 20

        switch step.action {
        case "launch":
            // The host trust preflight intentionally launches dev-vpn before
            // XCTest. Re-issuing launch asks XCTest to terminate that healthy
            // process first; CoreDevice on iOS 27 can hang in that termination
            // for a full minute. Activate an existing process and launch only
            // when the application is not already running.
            if app.state == .runningForeground || app.state == .runningBackground {
                app.activate()
            } else {
                app.launch()
            }
            try require(app.wait(for: .runningForeground, timeout: timeout), "app did not enter foreground")
        case "activate":
            app.activate()
            try require(app.wait(for: .runningForeground, timeout: timeout), "app did not enter foreground")
        case "terminate":
            app.terminate()
        case "home":
            XCUIDevice.shared.press(.home)
        case "wait":
            Thread.sleep(forTimeInterval: step.seconds ?? 1)
        case "disable_wifi":
            shouldRestoreWiFi = true
            try disableWiFi(timeout: timeout)
        case "enable_wifi":
            try setWiFiRadio(enabled: true, timeout: timeout)
            shouldRestoreWiFi = false
            XCUIDevice.shared.press(.home)
        case "tap":
            try coordinate(step, in: app).tap()
            if step.name == "disable-wifi" {
                shouldRestoreWiFi = true
            } else if step.name == "enable-wifi" {
                shouldRestoreWiFi = false
            }
        case "double_tap":
            try coordinate(step, in: app).doubleTap()
        case "long_press":
            try coordinate(step, in: app).press(forDuration: step.duration ?? 1)
        case "swipe":
            let start = try coordinate(step, in: app)
            guard let endX = step.endX, let endY = step.endY else {
                throw ScenarioError.invalidStep("swipe requires end_x and end_y")
            }
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: endY))
            start.press(
                forDuration: step.holdDuration ?? 0.05,
                thenDragTo: end,
                withVelocity: .default,
                thenHoldForDuration: step.endHoldDuration ?? 0
            )
        case "tap_element", "tap_any":
            try tapElement(findElement(step, in: app, timeout: timeout))
        case "tap_if_text":
            guard let text = step.text else { throw ScenarioError.invalidStep("tap_if_text requires text") }
            if app.staticTexts[text].firstMatch.exists {
                try tapElement(findElement(step, in: app, timeout: timeout))
            }
        case "tap_if_text_at":
            guard let text = step.text else { throw ScenarioError.invalidStep("tap_if_text_at requires text") }
            if app.staticTexts[text].firstMatch.exists {
                try coordinate(step, in: app).tap()
            }
        case "tap_if_identifier":
            guard let identifier = step.identifier else {
                throw ScenarioError.invalidStep("tap_if_identifier requires identifier")
            }
            let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if element.exists {
                try tapElement(element)
            }
        case "tap_if_any":
            if let element = findElementIfPresent(step, in: app, timeout: timeout) {
                try tapElement(element)
            }
        case "tap_and_assert_selected":
            try tapAndAssertSelected(step, in: app, timeout: timeout)
        case "dismiss_pip":
            let pip = app.windows.matching(identifier: "PIP-SBInteractionPassThroughView").firstMatch
            if pip.exists {
                pip.tap()
                let closeButton = pip.buttons.firstMatch
                try require(closeButton.waitForExistence(timeout: timeout), "PiP close button did not appear")
                closeButton.tap()
            }
        case "type":
            guard let text = step.text else { throw ScenarioError.invalidStep("type requires text") }
            app.typeText(text)
        case "type_into", "type_into_any":
            guard let text = step.text else { throw ScenarioError.invalidStep("type_into requires text") }
            let element = try findElement(step, in: app, timeout: timeout)
            element.tap()
            for _ in 0 ..< 2 where !app.keyboards.firstMatch.exists {
                Thread.sleep(forTimeInterval: 0.5)
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            try require(app.keyboards.firstMatch.waitForExistence(timeout: 2), "element did not open the software keyboard")
            app.typeText(text)
        case "wait_element", "wait_any":
            _ = try findElement(step, in: app, timeout: timeout)
        case "assert_any_absent":
            try require(findElementIfPresent(step, in: app, timeout: timeout) == nil, "unexpected element found: \(step.elementSummary)")
        case "assert_text":
            guard let text = step.text else { throw ScenarioError.invalidStep("assert_text requires text") }
            let element = app.staticTexts[text].firstMatch
            try require(element.waitForExistence(timeout: timeout), "text not found: \(text)")
        case "assert_connection_status":
            guard let text = step.text else {
                throw ScenarioError.invalidStep("assert_connection_status requires text")
            }
            let status = app.descendants(matching: .any).matching(
                identifier: "wlt.connection.status"
            ).firstMatch
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if status.exists, status.label == text { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
            let actualStatus = status.exists ? status.label : "missing"
            throw ScenarioError.failed(
                "connection status did not become \(text): \(actualStatus)"
            )
        case "assert_text_contains":
            guard let text = step.text else { throw ScenarioError.invalidStep("assert_text_contains requires text") }
            let element = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
            ).firstMatch
            try require(element.waitForExistence(timeout: timeout), "text fragment not found: \(text)")
        case "assert_text_absent":
            guard let text = step.text else { throw ScenarioError.invalidStep("assert_text_absent requires text") }
            let element = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
            ).firstMatch
            try require(!element.waitForExistence(timeout: timeout), "unexpected text found: \(text)")
        case "assert_web_loaded":
            try assertWebLoaded(step, in: app, timeout: timeout)
        case "assert_app_ready":
            try assertAppReady(step, in: app, timeout: timeout)
        case "assert_no_failure_text":
            try assertNoFailureText(step, in: app)
        case "assert_screen_changes":
            try assertScreenChanges(step)
        case "assert_value_changes":
            try assertValueChanges(step, in: app, timeout: timeout)
        case "select_outbound":
            try selectOutbound(step, in: app, timeout: timeout)
        case "open_telegram_saved_messages":
            try openTelegramSavedMessages(in: app, timeout: timeout)
        case "open_whatsapp_self_chat":
            try openWhatsAppSelfChat(step, in: app, timeout: timeout)
        case "youtube_quality":
            try selectYouTubeQuality(step, in: app, timeout: timeout)
        case "twitch_quality":
            try selectTwitchQuality(step, in: app, timeout: timeout)
        case "tap_twitch_live":
            try tapFirstTwitchLive(in: app, timeout: timeout)
        case "tap_twitch_vod":
            try tapFirstTwitchVOD(in: app, timeout: timeout)
        case "testflight_install":
            try installTestFlightApp(step, in: app, timeout: timeout)
        case "dns_probe":
            try dnsProbe(step)
        case "measure_download":
            try measureDownload(step, timeout: timeout)
        case "web_assets_probe":
            try webAssetsProbe(step, timeout: timeout)
        case "screenshot":
            attachScreenshot(named: step.name ?? "scenario")
        case "dump_ui":
            attachUIHierarchy(app, named: step.name ?? "ui-hierarchy")
        default:
            throw ScenarioError.invalidStep("unknown action: \(step.action)")
        }
    }

    private func openWiFiSettings(timeout: TimeInterval) throws -> (XCUIApplication, XCUIElement) {
        dismissNotificationPermissionAlertIfPresent(timeout: min(timeout, 2))
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        try require(settings.wait(for: .runningForeground, timeout: timeout), "Settings did not enter foreground")
        dismissNotificationPermissionAlertIfPresent(timeout: min(timeout, 2))

        var openedWiFiPage = false
        for _ in 0 ..< 5 {
            let wifiLabel = settings.staticTexts["Wi-Fi"].firstMatch
            if wifiLabel.waitForExistence(timeout: min(timeout, 5)) {
                if wifiLabel.isHittable {
                    wifiLabel.tap()
                } else {
                    // The iOS 27 Settings root exposes a compact inner Cell
                    // whose scroll-to-visible hit point is {-1,-1}, while the
                    // visible label still has usable screen geometry.
                    wifiLabel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                openedWiFiPage = true
                break
            }
            let wifiRow = settings.cells.containing(.staticText, identifier: "Wi-Fi").firstMatch
            if wifiRow.waitForExistence(timeout: 1), wifiRow.isHittable {
                wifiRow.tap()
                openedWiFiPage = true
                break
            }
            if settings.navigationBars.buttons.firstMatch.exists == false {
                settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43)).tap()
                openedWiFiPage = true
                break
            }
            let backButton = settings.navigationBars.buttons.firstMatch
            guard backButton.exists else { break }
            backButton.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }

        try require(openedWiFiPage, "Wi-Fi row not found in Settings")
        Thread.sleep(forTimeInterval: 0.5)
        let wifiSwitch = settings.switches.matching(
            NSPredicate(
                format: "identifier CONTAINS[c] %@ OR label IN %@",
                "wifi",
                ["Wi-Fi", "Wi‑Fi"]
            )
        ).firstMatch
        try require(wifiSwitch.waitForExistence(timeout: timeout), "Wi-Fi switch not found in Settings")
        return (settings, wifiSwitch)
    }

    private func dismissNotificationPermissionAlertIfPresent(timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notificationPrompt = springboard.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "Send You Notifications",
                "Notifications may include"
            )
        ).firstMatch
        guard notificationPrompt.waitForExistence(timeout: timeout) else { return }

        let denyButton = springboard.buttons.matching(
            NSPredicate(
                format: "label IN %@",
                ["Don’t Allow", "Don't Allow", "Не разрешать"]
            )
        ).firstMatch
        guard denyButton.waitForExistence(timeout: 2) else { return }
        denyButton.tap()
        _ = notificationPrompt.waitForNonExistence(timeout: 3)
    }

    private func waitForWiFiSwitch(
        in settings: XCUIApplication,
        enabled: Bool,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Resolve the switch again on every poll so a cached accessibility
            // value cannot hide a real transition.
            let wifiSwitch = settings.switches.matching(
                NSPredicate(
                    format: "identifier CONTAINS[c] %@ OR label IN %@",
                    "wifi",
                    ["Wi-Fi", "Wi‑Fi"]
                )
            ).firstMatch
            if wifiSwitch.exists, switchState(wifiSwitch) == enabled { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ScenarioError.failed("Wi-Fi switch did not become \(enabled ? "enabled" : "disabled")")
    }

    private func setWiFiRadio(enabled: Bool, timeout: TimeInterval) throws {
        let (settings, wifiSwitch) = try openWiFiSettings(timeout: timeout)
        guard let current = switchState(wifiSwitch) else {
            throw ScenarioError.failed("Wi-Fi switch returned an unknown value: \(String(describing: wifiSwitch.value))")
        }
        if current != enabled {
            tapWiFiSwitch(wifiSwitch)
            try waitForWiFiSwitch(in: settings, enabled: enabled, timeout: min(timeout, 10))
        }
        Thread.sleep(forTimeInterval: 5)
    }

    private func tapWiFiSwitch(_ wifiSwitch: XCUIElement) {
        // iOS 27 exposes a labelled switch spanning the entire 390pt settings
        // row and nests the actual 63pt control at its trailing edge. Tapping
        // the outer element's centre is accepted by XCTest but changes no
        // state. Prefer the nested control and retain a geometry fallback for
        // Settings variants that flatten the accessibility hierarchy.
        let nestedControl = wifiSwitch.descendants(matching: .switch).firstMatch
        if nestedControl.exists, nestedControl.frame.width < wifiSwitch.frame.width {
            nestedControl.tap()
        } else {
            wifiSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
    }

    private func activeNetworkUsesWiFi(timeout: TimeInterval) -> Bool? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "pro.2b2n.vpn.tests.network-path")
        monitor.start(queue: queue)
        defer { monitor.cancel() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let path = monitor.currentPath
            if path.status == .satisfied {
                NSLog(
                    "WLT_NETWORK_PATH status=satisfied wifi=%@ cellular=%@ expensive=%@ constrained=%@",
                    path.usesInterfaceType(.wifi) ? "true" : "false",
                    path.usesInterfaceType(.cellular) ? "true" : "false",
                    path.isExpensive ? "true" : "false",
                    path.isConstrained ? "true" : "false"
                )
                return path.usesInterfaceType(.wifi)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        NSLog("WLT_NETWORK_PATH status=unavailable timeout=%.1f", timeout)
        return nil
    }

    private func waitForCellularOnly(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if activeNetworkUsesWiFi(timeout: 1) == false { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func disableWiFi(timeout: TimeInterval) throws {
        // iOS 27 no longer exposes Control Center connectivity controls to
        // XCTest, and a coordinate tap can silently hit the wrong control.
        // Settings remains reachable over the USB XCTest channel even after
        // the Wi-Fi radio is disabled. Trust preflight has already completed
        // on Wi-Fi before the scenario starts, so use the real system switch
        // and restore it through the same path during teardown.
        shouldRestoreWiFi = true
        try setWiFiRadio(enabled: false, timeout: min(timeout, 30))
        attachScreenshot(named: "wifi-radio-disabled-settings")
        XCUIDevice.shared.press(.home)
        try require(
            waitForCellularOnly(timeout: timeout),
            "Wi-Fi remained the active network after disable_wifi"
        )
    }

    private func restoreWiFiIfNeeded() {
        guard shouldRestoreWiFi else { return }

        do {
            try setWiFiRadio(enabled: true, timeout: 30)
            try require(waitForWiFiActive(timeout: 30), "Wi-Fi radio enabled but no Wi-Fi path became active")
            attachScreenshot(named: "teardown-wifi-reconnected-settings")
            XCUIDevice.shared.press(.home)
        } catch {
            attachScreenshot(named: "teardown-wifi-restore-failed")
            XCTFail("Cleanup could not restore Wi-Fi through Settings: \(error)")
        }
        shouldRestoreWiFi = false
    }

    private func waitForWiFiActive(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if activeNetworkUsesWiFi(timeout: 1) == true { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func tapAndAssertSelected(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        let element = try findElement(step, in: app, timeout: timeout)
        if !element.isSelected {
            element.tap()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isSelected { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ScenarioError.failed("element did not become selected")
    }

    private func assertValueChanges(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        let element = try findElement(step, in: app, timeout: timeout)
        let initialValue = observableValue(element)
        let deadline = Date().addingTimeInterval(step.seconds ?? timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            let currentValue = observableValue(element)
            if !currentValue.isEmpty, currentValue != initialValue { return }
        }
        throw ScenarioError.failed("element value did not change from \(initialValue)")
    }

    private func assertWebLoaded(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: timeout) else {
            attachUIHierarchy(app, named: "\(step.name ?? "web")-missing-webview")
            throw ScenarioError.failed("web_missing_view")
        }

        let defaultFailureTexts = [
            "Safari не удается открыть страницу",
            "Не удается открыть страницу",
            "Safari cannot open the page",
            "Could not connect to the server",
            "Не удается установить безопасное соединение",
            "Cannot establish a secure connection",
            "сервер перестал отвечать",
            "The server stopped responding",
            "Нет подключения к интернету",
            "No Internet Connection",
            "You Are Offline",
        ]
        let failureTexts = step.failureTexts.isEmpty ? defaultFailureTexts : step.failureTexts
        let expectedTexts = step.expectedTexts
        let minimumElements = max(step.minimumElements ?? 1, 1)
        let deadline = Date().addingTimeInterval(timeout)
        var lastElementCount = 0
        var documentLoaded = false

        repeat {
            let failure = element(containingAny: failureTexts, in: webView)
            if failure.exists {
                attachUIHierarchy(app, named: "\(step.name ?? "web")-error-page")
                throw ScenarioError.failed("web_error_page: \(failureTexts.joined(separator: " | "))")
            }

            let loadedDocument = app.descendants(matching: .other).matching(
                NSPredicate(format: "identifier CONTAINS %@ AND identifier CONTAINS %@", "TabDocument?", "IsPageLoaded=true")
            ).firstMatch
            documentLoaded = loadedDocument.exists
            lastElementCount = webView.staticTexts.count + webView.links.count + webView.buttons.count + webView.images.count
            if documentLoaded, !expectedTexts.isEmpty {
                let expected = element(containingAny: expectedTexts, in: webView)
                if expected.exists { return }
            } else if documentLoaded, lastElementCount >= minimumElements {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline

        attachUIHierarchy(app, named: "\(step.name ?? "web")-content-missing")
        if !documentLoaded {
            throw ScenarioError.failed("web_load_stalled: IsPageLoaded=false meaningful_elements=\(lastElementCount)")
        } else if expectedTexts.isEmpty {
            throw ScenarioError.failed("web_empty_or_stalled: visible_elements=\(lastElementCount) minimum=\(minimumElements)")
        }
        throw ScenarioError.failed(
            "web_expected_content_missing: expected=\(expectedTexts.joined(separator: " | ")) visible_elements=\(lastElementCount)"
        )
    }

    private func assertAppReady(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        guard !step.identifiers.isEmpty || !step.labels.isEmpty || !step.containsTexts.isEmpty || !step.elementTypes.isEmpty else {
            throw ScenarioError.invalidStep("assert_app_ready requires a success marker")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var lastLoadingState = ""
        var loadingAtDeadline = false
        repeat {
            var isLoading = false
            if !step.authTexts.isEmpty {
                let auth = element(containingAny: step.authTexts, in: app)
                if auth.exists {
                    attachUIHierarchy(app, named: "\(step.name ?? step.app ?? "app")-auth-required")
                    throw ScenarioError.failed("app_auth_required: \(step.authTexts.joined(separator: " | "))")
                }
            }
            if !step.failureTexts.isEmpty {
                let failure = element(containingAny: step.failureTexts, in: app)
                if failure.exists {
                    attachUIHierarchy(app, named: "\(step.name ?? step.app ?? "app")-error-state")
                    throw ScenarioError.failed("app_error_state: \(step.failureTexts.joined(separator: " | "))")
                }
            }
            if !step.loadingTexts.isEmpty {
                let loading = element(containingAny: step.loadingTexts, in: app)
                if loading.exists {
                    lastLoadingState = step.loadingTexts.joined(separator: " | ")
                    isLoading = true
                }
            }
            if !step.loadingIdentifiers.isEmpty {
                let loadingQuery = app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier IN %@", step.loadingIdentifiers)
                )
                if loadingQuery.count > 0 {
                    lastLoadingState = step.loadingIdentifiers.joined(separator: " | ")
                    isLoading = true
                }
            }
            loadingAtDeadline = isLoading
            if !isLoading, findElementIfPresent(step, in: app, timeout: 0) != nil { return }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        attachUIHierarchy(app, named: "\(step.name ?? step.app ?? "app")-ready-timeout")
        if loadingAtDeadline, !lastLoadingState.isEmpty {
            throw ScenarioError.failed("app_loading_stalled: \(lastLoadingState)")
        }
        throw ScenarioError.failed("app_ready_timeout: \(step.elementSummary)")
    }

    private func assertNoFailureText(_ step: DeviceScenario.Step, in app: XCUIApplication) throws {
        guard !step.failureTexts.isEmpty else {
            throw ScenarioError.invalidStep("assert_no_failure_text requires failure_texts")
        }
        let failure = element(containingAny: step.failureTexts, in: app)
        if failure.exists {
            attachUIHierarchy(app, named: "\(step.name ?? step.app ?? "app")-error-state")
            throw ScenarioError.failed("app_error_state: \(step.failureTexts.joined(separator: " | "))")
        }
    }

    private func assertScreenChanges(_ step: DeviceScenario.Step) throws {
        let first = XCUIScreen.main.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: step.seconds ?? 5)
        let second = XCUIScreen.main.screenshot().pngRepresentation
        guard first != second else {
            throw ScenarioError.failed("screen_static: no visible change for \(step.seconds ?? 5)s")
        }
    }

    private func selectOutbound(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        guard let group = step.group, let outbound = step.outbound else {
            throw ScenarioError.invalidStep("select_outbound requires group and outbound")
        }
        app.activate()
        let groupsButton = app.descendants(matching: .any).matching(identifier: "wlt.groups.open").firstMatch
        if groupsButton.waitForExistence(timeout: timeout) {
            groupsButton.tap()
        }

        let groupElement = app.descendants(matching: .any).matching(identifier: "wlt.group.\(group)").firstMatch
        try require(groupElement.waitForExistence(timeout: timeout), "outbound group not found: \(group)")
        let itemIdentifier = "wlt.outbound.\(group).\(outbound)"
        var item = app.descendants(matching: .any).matching(identifier: itemIdentifier).firstMatch
        if !item.waitForExistence(timeout: 2) {
            let expand = app.descendants(matching: .any).matching(identifier: "wlt.group.\(group).expand").firstMatch
            try require(expand.waitForExistence(timeout: timeout), "group expand button not found: \(group)")
            expand.tap()
            item = app.descendants(matching: .any).matching(identifier: itemIdentifier).firstMatch
        }
        try require(item.waitForExistence(timeout: timeout), "outbound not found: \(outbound)")
        if stringValue(item.value) != "selected" {
            item.tap()
        }
        var selected = stringValue(item.value) == "selected" || item.isSelected
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stringValue(item.value) == "selected" || item.isSelected {
                selected = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try require(selected, "outbound did not become selected: \(group) -> \(outbound)")

        // Groups is a draggable sheet on iPhone. Leaving it presented hides
        // the connection status and can route later automation taps through a
        // stale accessibility element behind the sheet.
        let sheetGrabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let sheetBottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        sheetGrabber.press(
            forDuration: 0.05,
            thenDragTo: sheetBottom,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        Thread.sleep(forTimeInterval: 0.7)
    }

    private func selectYouTubeQuality(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        let preferred = step.preferredValues.isEmpty
            ? ["1080p60 HDR", "1080p60", "720p60 HDR", "720p60"]
            : step.preferredValues

        func openQualityModeSheet() {
            let qualityButton = app.descendants(matching: .any).matching(
                identifier: "id.player.watch.quality.button"
            ).firstMatch
            if qualityButton.waitForExistence(timeout: 3) {
                qualityButton.tap()
                return
            }

            // Current YouTube iOS exposes the settings sheet as a localized
            // row ("Качество" / "Quality") rather than the historical AX id.
            // The row's value (for example "Авто (360p60 HDR)") is accepted
            // as a fallback because the label can be omitted in some locales.
            let qualityRow = element(containingAny: ["Качество", "Quality", "Авто (", "Auto ("], in: app)
            if qualityRow.waitForExistence(timeout: 3), qualityRow.isHittable {
                qualityRow.tap()
            } else {
                // The sheet is rendered by a non-accessible native surface on
                // some YouTube builds. Its first row remains at a stable
                // relative position below the player controls.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
            }
        }

        let closeEngagementPanel = app.descendants(matching: .any).matching(
            identifier: "id.ui.browse.close.button"
        ).firstMatch
        if closeEngagementPanel.exists, closeEngagementPanel.isHittable {
            closeEngagementPanel.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Search results can open inline playback. The quality menu is only
        // exposed by the full player, where YouTube publishes stable AX
        // identifiers for overflow/settings and resolution cells.
        let fullscreen = app.descendants(matching: .any).matching(
            identifier: "id.player.watch.fullscreen.button"
        ).firstMatch
        if fullscreen.waitForExistence(timeout: 5), fullscreen.isHittable {
            fullscreen.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let overflow = app.descendants(matching: .any).matching(identifier: "id.player.overflow.button").firstMatch
        try require(overflow.waitForExistence(timeout: timeout), "YouTube player overflow button not found")
        overflow.tap()
        openQualityModeSheet()

        // YouTube first opens a quality mode sheet.  On current iOS builds
        // the fixed-resolution list is behind the localized "Другое"
        // ("Other") row; the resolution labels are not present until that
        // row is activated.  Prefer AX text, with a coordinate fallback for
        // the native sheet when its contents are not exposed to XCTest.
        let otherQuality = element(containingAny: ["Другое", "Other"], in: app)
        if otherQuality.waitForExistence(timeout: 3), otherQuality.isHittable {
            otherQuality.tap()
            Thread.sleep(forTimeInterval: 0.6)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            Thread.sleep(forTimeInterval: 0.6)
        }

        let selected: String
        do {
            // Some releases publish the fixed-resolution rows normally.
            selected = try tapFirstPreferred(preferred, in: app, timeout: min(timeout, 2))
        } catch {
            // YouTube 21.x renders the resolution strings visually while AX
            // exposes only unlabeled full-width 48pt buttons.  Preserve their
            // visual order and activate the third/fourth row for 1080p/720p.
            var unlabeledRows: [XCUIElement] = []
            var buttonDiagnostics: [String] = []
            let buttons = app.buttons
            for attempt in 0 ..< 15 {
                unlabeledRows.removeAll()
                buttonDiagnostics.removeAll()
                for index in 0 ..< min(buttons.count, 100) {
                    let candidate = buttons.element(boundBy: index)
                    guard candidate.exists else { continue }
                    let frame = candidate.frame
                    if index < 40 {
                        buttonDiagnostics.append(String(format: "%d: x=%.0f y=%.0f w=%.0f h=%.0f label=%@ id=%@", index, frame.minX, frame.minY, frame.width, frame.height, candidate.label, candidate.identifier))
                    }
                    guard frame.width >= 380,
                          frame.height >= 40,
                          frame.height <= 56,
                          frame.minY >= 450 else { continue }
                    unlabeledRows.append(candidate)
                }
                if !unlabeledRows.isEmpty || attempt == 14 { break }
                Thread.sleep(forTimeInterval: 0.4)
            }
            unlabeledRows.sort { $0.frame.minY < $1.frame.minY }

            let preferredRow: (value: String, index: Int)?
            if let value = preferred.first(where: { $0.localizedCaseInsensitiveContains("1080p60") }) {
                preferredRow = (value, 2)
            } else if let value = preferred.first(where: { $0.localizedCaseInsensitiveContains("720p60") }) {
                preferredRow = (value, 3)
            } else {
                preferredRow = nil
            }

            guard let preferredRow else {
                attachUIHierarchy(app, named: "youtube-quality-unavailable")
                attachScreenshot(named: "youtube-quality-unavailable")
                throw error
            }
            selected = preferredRow.value

            let rowFrames = unlabeledRows.map {
                String(format: "x=%.0f y=%.0f w=%.0f h=%.0f", $0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height)
            }.joined(separator: "\n")
            let geometry = XCTAttachment(string: "target_index=\(preferredRow.index) target=\(selected)\nrows:\n\(rowFrames)\nbuttons:\n\(buttonDiagnostics.joined(separator: "\\n"))")
            geometry.name = "youtube-quality-row-geometry"
            geometry.lifetime = .keepAlways
            add(geometry)

            if unlabeledRows.indices.contains(preferredRow.index) {
                unlabeledRows[preferredRow.index].tap()
            } else {
                // Application coordinates exclude the status bar.  The
                // visible 1080p/720p row centres therefore map to roughly
                // 0.58/0.64 rather than the full-screen 0.61/0.66 values.
                let fallbackY = preferredRow.index == 2 ? 0.58 : 0.64
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fallbackY)).tap()
            }
        }
        Thread.sleep(forTimeInterval: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        if overflow.waitForExistence(timeout: 3) {
            overflow.tap()
            let settingsEvidence = element(containingAny: [selected], in: app)
            if !settingsEvidence.waitForExistence(timeout: 2) {
                openQualityModeSheet()
            }
        }
        let evidence = element(containingAny: [selected], in: app)
        try require(evidence.waitForExistence(timeout: timeout), "selected YouTube quality is not visible: \(selected)")
        attachScreenshot(named: "youtube-quality-\(safeName(selected))")
    }

    private func openTelegramSavedMessages(in app: XCUIApplication, timeout: TimeInterval) throws {
        app.launch()
        let savedHeader = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Избранное")).firstMatch
        if savedHeader.exists, app.textViews.firstMatch.exists { return }

        let searchButton = app.buttons.matching(NSPredicate(format: "label == %@", "Поиск")).firstMatch
        if searchButton.waitForExistence(timeout: 3) {
            searchButton.tap()
        } else {
            let searchIcon = app.descendants(matching: .any).matching(identifier: "Navigation/Search").firstMatch
            try require(searchIcon.waitForExistence(timeout: timeout), "Telegram search trigger not found")
            searchIcon.tap()
        }
        let searchDeadline = Date().addingTimeInterval(timeout)
        var selectedSearchField: XCUIElement?
        while Date() < searchDeadline, selectedSearchField == nil {
            selectedSearchField = firstUsable(app.searchFields)
            if selectedSearchField == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard let searchField = selectedSearchField else {
            throw ScenarioError.failed("Telegram search field not found")
        }
        if !stringValue(searchField.value).localizedCaseInsensitiveContains("Избранное") {
            searchField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try require(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Telegram search field did not receive keyboard focus")
            searchField.typeText("Избранное")
        }

        let results = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Избранное"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in 0 ..< results.count {
                let result = results.element(boundBy: index)
                if result.exists, result.isHittable, result.frame.width > 40, result.frame.height > 20 {
                    result.tap()
                    try require(app.textViews.firstMatch.waitForExistence(timeout: timeout), "Telegram Saved Messages composer not found")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ScenarioError.failed("Telegram local Saved Messages result not found")
    }

    private func openWhatsAppSelfChat(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        guard let target = step.label else {
            throw ScenarioError.invalidStep("open_whatsapp_self_chat requires label")
        }
        app.launch()
        let selfCaption = app.descendants(matching: .any).matching(identifier: "NavigationBar_CaptionLabel").firstMatch
        if selfCaption.exists, selfCaption.label.localizedCaseInsensitiveContains("Сообщение для себя") { return }

        let chatList = app.descendants(matching: .any).matching(identifier: "ChatListView_TableView").firstMatch
        for _ in 0 ..< 3 where !chatList.exists {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        try require(chatList.waitForExistence(timeout: timeout), "WhatsApp chat list not found")

        let candidates = app.cells.matching(NSPredicate(format: "label == %@", target))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in 0 ..< candidates.count {
                let candidate = candidates.element(boundBy: index)
                let youBadge = candidate.descendants(matching: .any).matching(identifier: "WABadgedLabel_You").firstMatch
                if candidate.exists, candidate.isHittable, youBadge.exists {
                    candidate.tap()
                    try require(selfCaption.waitForExistence(timeout: timeout), "WhatsApp self-chat caption not found")
                    try require(selfCaption.label.localizedCaseInsensitiveContains("Сообщение для себя"), "WhatsApp target is not the self chat")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ScenarioError.failed("WhatsApp self-chat target was not found: \(target)")
    }

    private func selectTwitchQuality(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws {
        let qualityIdentifiers = step.identifiers.isEmpty ? ["cell_720p60"] : step.identifiers
        let videoLayer = app.descendants(matching: .any).matching(identifier: "video_layer_view").firstMatch
        try require(videoLayer.waitForExistence(timeout: timeout), "Twitch theater video layer not found")
        let options = app.descendants(matching: .any).matching(identifier: "options_button").firstMatch

        func throwIfPlaybackFailed() throws {
            let failureTexts = [
                "Произошла ошибка. Повторите попытку.",
                "Ошибка воспроизведения",
                "Playback error",
            ]
            for text in failureTexts {
                let failure = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
                ).firstMatch
                if failure.exists {
                    attachUIHierarchy(app, named: "twitch-playback-error")
                    throw ScenarioError.failed("app_error_state: Twitch playback failed before quality selection")
                }
            }
        }

        func showPlayerOptions() throws {
            if options.exists, options.isHittable { return }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try throwIfPlaybackFailed()
                // The center of Twitch's pre-roll player is its pause button.
                // Repeated center taps freeze the ad forever and prevent the
                // stream-only options button from ever appearing. A corner tap
                // reveals normal player controls without toggling ad playback.
                videoLayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
                if options.waitForExistence(timeout: min(1.5, max(0.1, deadline.timeIntervalSinceNow))), options.isHittable {
                    return
                }
            }
            throw ScenarioError.failed("Twitch player options button not found")
        }

        func tapPlayerOptions() throws {
            try showPlayerOptions()
            // Twitch auto-hides its controls aggressively. Capturing the
            // button frame first avoids a second XCUI snapshot between the
            // hittability check and the synthesized tap.
            let buttonFrame = options.frame
            let appFrame = app.frame
            guard buttonFrame.width > 0, buttonFrame.height > 0,
                  appFrame.width > 0, appFrame.height > 0
            else {
                throw ScenarioError.failed("Twitch player options button has an invalid frame")
            }
            let offset = CGVector(
                dx: (buttonFrame.midX - appFrame.minX) / appFrame.width,
                dy: (buttonFrame.midY - appFrame.minY) / appFrame.height
            )
            app.coordinate(withNormalizedOffset: offset).tap()
        }

        func qualityMenuIsVisible() -> Bool {
            let lowLatency = app.descendants(matching: .any).matching(identifier: "low_latency_switch").firstMatch
            if lowLatency.exists { return true }
            for identifier in qualityIdentifiers {
                let quality = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                if quality.exists { return true }
            }
            return false
        }

        func openPlayerOptionsMenu() throws {
            for attempt in 1 ... 3 {
                try tapPlayerOptions()
                let menuDeadline = Date().addingTimeInterval(min(3, timeout))
                while Date() < menuDeadline {
                    try throwIfPlaybackFailed()
                    if qualityMenuIsVisible() { return }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            attachUIHierarchy(app, named: "twitch-options-menu-unavailable")
            throw ScenarioError.failed("Twitch player options menu did not open")
        }

        func closePlayerOptionsMenu() throws {
            let closeLabels = ["Закрыть", "Close", "Готово", "Done"]
            var closeButton: XCUIElement?
            for label in closeLabels {
                let candidate = app.buttons[label].firstMatch
                if candidate.exists, candidate.isHittable {
                    closeButton = candidate
                    break
                }
            }
            if let closeButton {
                closeButton.tap()
            } else {
                // Twitch does not consistently expose an accessibility label
                // for the top-right close glyph.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.06)).tap()
            }
            let closeDeadline = Date().addingTimeInterval(min(3, timeout))
            while Date() < closeDeadline {
                if !qualityMenuIsVisible() { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw ScenarioError.failed("Twitch player options menu did not close")
        }

        try openPlayerOptionsMenu()

        if step.text == "disable_low_latency" {
            let lowLatency = app.descendants(matching: .any).matching(identifier: "low_latency_switch").firstMatch
            if lowLatency.waitForExistence(timeout: min(3, timeout)), stringValue(lowLatency.value) == "1" {
                lowLatency.tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }

        let qualityDeadline = Date().addingTimeInterval(timeout)
        var qualityIdentifier = ""
        var quality: XCUIElement?
        while Date() < qualityDeadline, quality == nil {
            for identifier in qualityIdentifiers {
                let candidate = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                if candidate.exists, candidate.isHittable {
                    qualityIdentifier = identifier
                    quality = candidate
                    break
                }
            }
            if quality == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard var quality else {
            attachUIHierarchy(app, named: "twitch-quality-unavailable")
            throw ScenarioError.failed("Twitch quality not found: \(qualityIdentifiers.joined(separator: ", "))")
        }
        if !quality.isSelected {
            quality.tap()
            Thread.sleep(forTimeInterval: 1)
            try openPlayerOptionsMenu()
            quality = app.descendants(matching: .any).matching(identifier: qualityIdentifier).firstMatch
        }
        try require(quality.waitForExistence(timeout: timeout) && quality.isSelected, "Twitch quality was not selected: \(qualityIdentifier)")
        attachScreenshot(named: "twitch-quality-\(qualityIdentifier.replacingOccurrences(of: "cell_", with: ""))")
        try closePlayerOptionsMenu()
    }

    private func tapFirstTwitchLive(in app: XCUIApplication, timeout: TimeInterval) throws {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "stream_",
            "В ЭФИРЕ"
        )
        let streams = app.buttons.matching(predicate)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let stream = firstUsable(streams), stream.isHittable {
                stream.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        attachUIHierarchy(app, named: "twitch-live-stream-missing")
        throw ScenarioError.failed("element not found: hittable Twitch stream button")
    }

    private func tapFirstTwitchVOD(in app: XCUIApplication, timeout: TimeInterval) throws {
        let videos = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "video_")
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let video = firstUsable(videos), video.isHittable {
                video.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        attachUIHierarchy(app, named: "twitch-vod-missing")
        throw ScenarioError.failed("element not found: hittable Twitch VOD button")
    }

    private func tapFirstPreferred(_ values: [String], in app: XCUIApplication, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for value in values {
                let candidate = element(containingAny: [value], in: app)
                if candidate.exists, candidate.isHittable {
                    candidate.tap()
                    return value
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ScenarioError.failed("none of the preferred values appeared: \(values.joined(separator: ", "))")
    }

    private func installTestFlightApp(
        _ step: DeviceScenario.Step,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws {
        guard let appName = step.text, !appName.isEmpty else {
            throw ScenarioError.invalidStep("testflight_install requires text with the TestFlight app name")
        }

        let title = app.staticTexts[appName].firstMatch
        try require(title.waitForExistence(timeout: timeout), "TestFlight app not found: \(appName)")
        var targetY = title.frame.midY

        if button(in: app, labels: ["Открыть", "Open"], nearY: targetY) != nil {
            return
        }

        guard let installButton = button(
            in: app,
            labels: ["Установить", "Install", "Обновить", "Update"],
            nearY: targetY
        ) else {
            throw ScenarioError.failed("TestFlight install button not found for: \(appName)")
        }
        installButton.tap()

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let alert = app.alerts.firstMatch
            if alert.exists {
                let details = alert.staticTexts.allElementsBoundByIndex
                    .map(\.label)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let dismiss = alert.buttons["OK"].firstMatch
                if dismiss.exists, dismiss.isHittable {
                    dismiss.tap()
                }
                throw ScenarioError.failed(
                    "app_error_state: TestFlight install failed for \(appName): \(details)"
                )
            }
            if title.exists {
                targetY = title.frame.midY
            }
            if button(in: app, labels: ["Открыть", "Open"], nearY: targetY) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        throw ScenarioError.failed("TestFlight install did not complete for: \(appName)")
    }

    private func measureDownload(_ step: DeviceScenario.Step, timeout: TimeInterval) throws {
        guard let rawURL = step.text, let url = URL(string: rawURL), let host = url.host else {
            throw ScenarioError.invalidStep("measure_download requires an absolute URL in text")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let result = DownloadResultBox()
        let completed = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        if let rangeBytes = step.rangeBytes, rangeBytes > 0 {
            request.setValue("bytes=0-\(rangeBytes - 1)", forHTTPHeaderField: "Range")
        }

        let startedAt = Date()
        let task = session.dataTask(with: request) { data, response, error in
            result.store(
                bytes: data?.count ?? 0,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                error: error?.localizedDescription
            )
            completed.signal()
        }
        task.resume()

        guard completed.wait(timeout: .now() + timeout + 5) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw ScenarioError.failed("download timeout from \(host)")
        }
        session.finishTasksAndInvalidate()

        let finishedAt = Date()
        let elapsed = max(finishedAt.timeIntervalSince(startedAt), 0.001)
        let snapshot = result.snapshot()
        let bytesPerSecond = Double(snapshot.bytes) / elapsed
        let measurement = String(
            format: "host=%@ status=%d bytes=%d elapsed_ms=%.0f bytes_per_second=%.0f kib_per_second=%.1f started_at_unix_ms=%.0f finished_at_unix_ms=%.0f",
            host,
            snapshot.statusCode,
            snapshot.bytes,
            elapsed * 1000,
            bytesPerSecond,
            bytesPerSecond / 1024,
            startedAt.timeIntervalSince1970 * 1000,
            finishedAt.timeIntervalSince1970 * 1000
        )
        let attachment = XCTAttachment(string: measurement)
        attachment.name = "wlt-metric-download-\(step.name ?? "download")"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let error = snapshot.error {
            throw ScenarioError.failed("download failed from \(host): \(error)")
        }
        try require((200 ..< 300).contains(snapshot.statusCode), "download HTTP status from \(host): \(snapshot.statusCode)")
        if let minimumBytes = step.minimumBytes {
            try require(snapshot.bytes >= minimumBytes, "download too short from \(host): \(snapshot.bytes) < \(minimumBytes)")
        }
        if let minimumBytesPerSecond = step.minimumBytesPerSecond {
            try require(
                bytesPerSecond >= minimumBytesPerSecond,
                "download too slow from \(host): \(Int(bytesPerSecond)) < \(Int(minimumBytesPerSecond)) B/s"
            )
        }
    }

    private func webAssetsProbe(_ step: DeviceScenario.Step, timeout: TimeInterval) throws {
        guard let rawURL = step.text, let pageURL = URL(string: rawURL), pageURL.host != nil else {
            throw ScenarioError.invalidStep("web_assets_probe requires an absolute URL in text")
        }
        let maximumAssets = step.maximumAssets ?? 10
        let minimumSuccessfulAssets = step.minimumSuccessfulAssets ?? 3
        let minimumAssetBytes = step.minimumAssetBytes ?? 32_768
        let assetReadLimitBytes = step.assetReadLimitBytes ?? 1_048_576
        let concurrency = step.concurrency ?? 6
        let allowSiteChallenge = step.allowSiteChallenge ?? false
        guard (1 ... 32).contains(maximumAssets) else {
            throw ScenarioError.invalidStep("maximum_assets must be within 1...32")
        }
        guard (1 ... maximumAssets).contains(minimumSuccessfulAssets) else {
            throw ScenarioError.invalidStep("minimum_successful_assets must be within 1...maximum_assets")
        }
        guard (1 ... maximumAssets).contains(concurrency) else {
            throw ScenarioError.invalidStep("concurrency must be within 1...maximum_assets")
        }
        guard assetReadLimitBytes > 0 else {
            throw ScenarioError.invalidStep("asset_read_limit_bytes must be positive")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = concurrency
        let session = URLSession(configuration: configuration)
        let pageResult = WebPageResultBox()
        let pageCompleted = DispatchSemaphore(value: 0)
        var pageRequest = URLRequest(url: pageURL)
        pageRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        pageRequest.timeoutInterval = timeout
        pageRequest.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        pageRequest.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let startedAt = Date()
        let pageStartedAt = Date()
        let pageTask = session.dataTask(with: pageRequest) { data, response, error in
            let httpResponse = response as? HTTPURLResponse
            pageResult.store(
                data: data ?? Data(),
                statusCode: httpResponse?.statusCode ?? 0,
                resolvedURL: httpResponse?.url,
                error: error?.localizedDescription
            )
            pageCompleted.signal()
        }
        pageTask.resume()
        guard pageCompleted.wait(timeout: .now() + timeout + 5) == .success else {
            pageTask.cancel()
            session.invalidateAndCancel()
            throw ScenarioError.failed("web page timeout from \(pageURL.host ?? "unknown")")
        }
        let pageElapsedMilliseconds = Date().timeIntervalSince(pageStartedAt) * 1000
        let pageSnapshot = pageResult.snapshot()
        if let error = pageSnapshot.error {
            session.invalidateAndCancel()
            throw ScenarioError.failed("web page failed from \(pageURL.host ?? "unknown"): \(error)")
        }
        guard !pageSnapshot.data.isEmpty else {
            session.invalidateAndCancel()
            throw ScenarioError.failed("web page returned an empty response")
        }
        let html = String(data: pageSnapshot.data, encoding: .utf8)
            ?? String(data: pageSnapshot.data, encoding: .isoLatin1)
            ?? ""
        let siteChallenge = (400 ..< 500).contains(pageSnapshot.statusCode) && (
            html.localizedCaseInsensitiveContains("challenge-error-text") ||
                html.localizedCaseInsensitiveContains("captcha")
            )
        if siteChallenge && allowSiteChallenge {
            session.finishTasksAndInvalidate()
            let finishedAt = Date()
            let measurement = String(
                format: "page_status=%d page_bytes=%d page_duration_ms=%.0f site_reject=true discovered_assets=0 requested_assets=0 successful_assets=0 asset_bytes=0 duration_ms=%.0f asset_p50_ms=0 asset_p95_ms=0 asset_max_ms=0 started_at_unix_ms=%.0f finished_at_unix_ms=%.0f error_counts=SITE_CHALLENGE:1",
                pageSnapshot.statusCode,
                pageSnapshot.data.count,
                pageElapsedMilliseconds,
                finishedAt.timeIntervalSince(startedAt) * 1000,
                startedAt.timeIntervalSince1970 * 1000,
                finishedAt.timeIntervalSince1970 * 1000
            )
            let attachment = XCTAttachment(string: measurement)
            attachment.name = "wlt-metric-web-assets-\(step.name ?? "web-assets")"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        try require((200 ..< 400).contains(pageSnapshot.statusCode), "web page HTTP status: \(pageSnapshot.statusCode)")
        let baseURL = pageSnapshot.resolvedURL ?? pageURL
        let discoveredAssets = try extractWebAssets(from: html, relativeTo: baseURL)
        let assets = Array(discoveredAssets.prefix(maximumAssets))
        guard assets.count >= minimumSuccessfulAssets else {
            session.invalidateAndCancel()
            throw ScenarioError.failed("web page exposed only \(assets.count) usable image assets")
        }

        let assetResults = WebAssetResultsBox()
        let assetGroup = DispatchGroup()
        for assetURL in assets {
            assetGroup.enter()
            var request = URLRequest(url: assetURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = timeout
            request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue("bytes=0-\(assetReadLimitBytes - 1)", forHTTPHeaderField: "Range")
            let assetStartedAt = Date()
            let task = session.dataTask(with: request) { data, response, error in
                let httpResponse = response as? HTTPURLResponse
                let bytes = min(data?.count ?? 0, assetReadLimitBytes)
                let statusCode = httpResponse?.statusCode ?? 0
                let contentType = httpResponse?.mimeType ?? ""
                let validContent = contentType.lowercased().hasPrefix("image/") || bytes >= 4_096
                let success = error == nil && (200 ..< 400).contains(statusCode) && bytes > 0 && validContent
                let problem = error?.localizedDescription ?? (validContent ? "" : "INVALID_CONTENT")
                assetResults.append(
                    WebAssetResult(
                        success: success,
                        statusCode: statusCode,
                        bytes: bytes,
                        durationMilliseconds: Date().timeIntervalSince(assetStartedAt) * 1000,
                        error: problem
                    )
                )
                assetGroup.leave()
            }
            task.resume()
        }
        let waves = Int(ceil(Double(assets.count) / Double(concurrency)))
        let completed = assetGroup.wait(timeout: .now() + timeout * Double(waves) + 10) == .success
        if !completed {
            session.invalidateAndCancel()
        } else {
            session.finishTasksAndInvalidate()
        }

        let finishedAt = Date()
        let results = assetResults.snapshot()
        let successful = results.filter(\.success)
        let durations = results.map(\.durationMilliseconds).sorted()
        let totalAssetBytes = successful.reduce(0) { $0 + $1.bytes }
        let errors = Dictionary(grouping: results.filter { !$0.success }) { result in
            if !result.error.isEmpty { return result.error.replacingOccurrences(of: " ", with: "_") }
            return "HTTP_\(result.statusCode)"
        }.mapValues(\.count)
        let errorSummary = errors.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        let measurement = String(
            format: "page_status=%d page_bytes=%d page_duration_ms=%.0f site_reject=false discovered_assets=%d requested_assets=%d successful_assets=%d minimum_successful_assets=%d asset_bytes=%d duration_ms=%.0f asset_p50_ms=%.0f asset_p95_ms=%.0f asset_max_ms=%.0f started_at_unix_ms=%.0f finished_at_unix_ms=%.0f error_counts=%@",
            pageSnapshot.statusCode,
            pageSnapshot.data.count,
            pageElapsedMilliseconds,
            discoveredAssets.count,
            assets.count,
            successful.count,
            minimumSuccessfulAssets,
            totalAssetBytes,
            finishedAt.timeIntervalSince(startedAt) * 1000,
            percentile(durations, 0.50),
            percentile(durations, 0.95),
            durations.last ?? 0,
            startedAt.timeIntervalSince1970 * 1000,
            finishedAt.timeIntervalSince1970 * 1000,
            errorSummary.isEmpty ? "none" : errorSummary
        )
        let attachment = XCTAttachment(string: measurement)
        attachment.name = "wlt-metric-web-assets-\(step.name ?? "web-assets")"
        attachment.lifetime = .keepAlways
        add(attachment)

        try require(completed, "web asset requests timed out: \(results.count)/\(assets.count)")
        try require(results.count == assets.count, "web asset requests incomplete: \(results.count)/\(assets.count)")
        try require(
            successful.count >= minimumSuccessfulAssets,
            "too few image assets loaded: \(successful.count) < \(minimumSuccessfulAssets); errors=\(errorSummary)"
        )
        try require(totalAssetBytes >= minimumAssetBytes, "image assets too short: \(totalAssetBytes) < \(minimumAssetBytes)")
    }

    private func extractWebAssets(from html: String, relativeTo baseURL: URL) throws -> [URL] {
        let pattern = #"\b(srcset|data-srcset|src|data-src|data-original|data-lazy-src)\s*=\s*([\"'])(.*?)\2"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let fullRange = NSRange(html.startIndex ..< html.endIndex, in: html)
        var seen = Set<String>()
        var result: [URL] = []
        for match in expression.matches(in: html, range: fullRange) {
            guard let attributeRange = Range(match.range(at: 1), in: html),
                  let valueRange = Range(match.range(at: 3), in: html) else { continue }
            let attribute = String(html[attributeRange])
            let rawValue = String(html[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
            let candidates = attribute.lowercased().contains("srcset")
                ? rawValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? "" }
                : [rawValue.trimmingCharacters(in: .whitespacesAndNewlines)]
            for candidate in candidates where !candidate.isEmpty && !candidate.lowercased().hasPrefix("data:") {
                guard let url = URL(string: candidate, relativeTo: baseURL)?.absoluteURL,
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                if seen.insert(url.absoluteString).inserted { result.append(url) }
            }
        }
        return result
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = max(0, min(values.count - 1, Int(ceil(Double(values.count) * fraction)) - 1))
        return values[index]
    }

    private func dnsProbe(_ step: DeviceScenario.Step) throws {
        guard let host = step.text, !host.isEmpty else {
            throw ScenarioError.invalidStep("dns_probe requires a hostname in text")
        }

        let queryHost: String
        if step.cacheBust ?? false {
            let nonce = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            queryHost = "wlt-\(nonce).\(host)"
        } else {
            queryHost = host
        }
        guard queryHost.utf8.count <= 253 else {
            throw ScenarioError.invalidStep("dns_probe hostname is too long after cache busting")
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        let startedAt = Date()
        let status = queryHost.withCString { pointer in
            getaddrinfo(pointer, nil, &hints, &result)
        }
        if let result {
            freeaddrinfo(result)
        }

        let finishedAt = Date()
        let elapsed = max(finishedAt.timeIntervalSince(startedAt), 0.001)
        let success = status == 0
        let expectedSuccess = step.expectedSuccess ?? true
        let message = String(
            format: "host=%@ status=%d elapsed_ms=%.0f success=%@ started_at_unix_ms=%.0f finished_at_unix_ms=%.0f",
            queryHost,
            status,
            elapsed * 1000,
            success ? "true" : "false",
            startedAt.timeIntervalSince1970 * 1000,
            finishedAt.timeIntervalSince1970 * 1000
        )
        let attachment = XCTAttachment(string: message)
        attachment.name = "wlt-metric-dns-\(step.name ?? "dns-probe")"
        attachment.lifetime = .keepAlways
        add(attachment)

        if success != expectedSuccess {
            throw ScenarioError.failed("DNS probe expectation mismatch for \(queryHost): status \(status)")
        }
    }

    private func button(in app: XCUIApplication, labels: [String], nearY targetY: CGFloat) -> XCUIElement? {
        let query = app.buttons.matching(NSPredicate(format: "label IN %@", labels))
        var best: XCUIElement?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0 ..< min(query.count, 30) {
            let candidate = query.element(boundBy: index)
            guard candidate.exists else { continue }
            let distance = abs(candidate.frame.midY - targetY)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        guard bestDistance <= 45 else { return nil }
        return best
    }

    private func findElement(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws -> XCUIElement {
        guard !step.identifiers.isEmpty || !step.labels.isEmpty || !step.containsTexts.isEmpty || !step.elementTypes.isEmpty else {
            throw ScenarioError.invalidStep("element action requires identifier(s), label(s), contains_text(s), or element_type(s)")
        }
        guard let element = findElementIfPresent(step, in: app, timeout: timeout) else {
            throw ScenarioError.failed("element not found: \(step.elementSummary)")
        }
        return element
    }

    private func tapElement(_ element: XCUIElement) throws {
        if element.isHittable {
            element.tap()
            return
        }
        let frame = element.frame
        guard !frame.isEmpty, frame.width > 0, frame.height > 0 else {
            throw ScenarioError.failed("element is not hittable and has no visible frame")
        }
        // SwiftUI's iOS 26+ tab-bar accessory can expose a visible control
        // with a valid screen frame while XCTest reports isHittable=false.
        // A coordinate tap avoids the broken scroll-to-visible hit point.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func findElementIfPresent(
        _ step: DeviceScenario.Step,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for identifier in step.identifiers {
                let query = app.descendants(matching: .any).matching(identifier: identifier)
                if let element = firstUsable(query) { return element }
            }
            for label in step.labels {
                let query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                if let element = firstUsable(query) { return element }
            }
            if !step.containsTexts.isEmpty {
                let element = element(containingAny: step.containsTexts, in: app)
                if element.exists { return element }
            }
            for type in step.elementTypes {
                if let element = firstUsable(query(ofType: type, in: app)) { return element }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return nil
    }

    private func element(containingAny values: [String], in app: XCUIApplication) -> XCUIElement {
        let predicates = values.map { value in
            NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR value CONTAINS[c] %@", value, value, value)
        }
        return app.descendants(matching: .any).matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates)).firstMatch
    }

    private func element(containingAny values: [String], in root: XCUIElement) -> XCUIElement {
        guard !values.isEmpty else {
            return root.descendants(matching: .any).matching(identifier: "__no_values__").firstMatch
        }
        let predicates = values.map { value in
            NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR value CONTAINS[c] %@", value, value, value)
        }
        return root.descendants(matching: .any).matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates)).firstMatch
    }

    private func query(ofType type: String, in app: XCUIApplication) -> XCUIElementQuery {
        switch type {
        case "button": return app.buttons
        case "cell": return app.cells
        case "search_field": return app.searchFields
        case "text_field": return app.textFields
        case "text_view": return app.textViews
        default: return app.descendants(matching: .any).matching(identifier: "__unsupported_element_type_\(type)")
        }
    }

    private func firstUsable(_ query: XCUIElementQuery) -> XCUIElement? {
        var fallback: XCUIElement?
        for index in 0 ..< min(query.count, 20) {
            let element = query.element(boundBy: index)
            guard element.exists else { continue }
            if element.isHittable { return element }
            if fallback == nil { fallback = element }
        }
        return fallback
    }

    private func application(named name: String) -> XCUIApplication {
        guard let app = apps[name] else {
            XCTFail("Unknown app alias: \(name)")
            return apps["vpn"]!
        }
        return app
    }

    private func coordinate(_ step: DeviceScenario.Step, in app: XCUIApplication) throws -> XCUICoordinate {
        guard let x = step.x, let y = step.y, (0 ... 1).contains(x), (0 ... 1).contains(y) else {
            throw ScenarioError.invalidStep("coordinate requires normalized x and y in 0...1")
        }
        return app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func switchState(_ element: XCUIElement) -> Bool? {
        if let value = element.value as? NSNumber {
            return value.boolValue
        }
        if let value = element.value as? String {
            switch value.lowercased() {
            case "1", "on", "true": return true
            case "0", "off", "false": return false
            default: return nil
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String {
        if let value { return String(describing: value) }
        return ""
    }

    private func observableValue(_ element: XCUIElement) -> String {
        [element.label, stringValue(element.value)].filter { !$0.isEmpty }.joined(separator: " | ")
    }

    private func safeName(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
    }

    private func attachUIHierarchy(_ app: XCUIApplication, named name: String) {
        let hierarchy = app.debugDescription.replacingOccurrences(of: "\u{0000}", with: "")
        var index = hierarchy.startIndex
        var part = 1
        while index < hierarchy.endIndex {
            let end = hierarchy.index(index, offsetBy: 16000, limitedBy: hierarchy.endIndex) ?? hierarchy.endIndex
            let attachment = XCTAttachment(string: String(hierarchy[index ..< end]))
            attachment.name = String(format: "%@-%03d", name, part)
            attachment.lifetime = .keepAlways
            add(attachment)
            index = end
            part += 1
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ScenarioError.failed(message) }
    }

    private static let webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class WebPageResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var statusCode = 0
    private var resolvedURL: URL?
    private var error: String?

    func store(data: Data, statusCode: Int, resolvedURL: URL?, error: String?) {
        lock.lock()
        self.data = data
        self.statusCode = statusCode
        self.resolvedURL = resolvedURL
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (data: Data, statusCode: Int, resolvedURL: URL?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, statusCode, resolvedURL, error)
    }
}

private struct WebAssetResult: Sendable {
    let success: Bool
    let statusCode: Int
    let bytes: Int
    let durationMilliseconds: Double
    let error: String
}

private final class WebAssetResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [WebAssetResult] = []

    func append(_ result: WebAssetResult) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    func snapshot() -> [WebAssetResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

private final class DownloadResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var statusCode = 0
    private var error: String?

    func store(bytes: Int, statusCode: Int, error: String?) {
        lock.lock()
        self.bytes = bytes
        self.statusCode = statusCode
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (bytes: Int, statusCode: Int, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, statusCode, error)
    }
}

private struct DeviceScenario: Decodable {
    let name: String
    let apps: [String: String]
    let steps: [Step]
    let continueOnFailure: Bool
    let cleanupSteps: [Step]

    enum CodingKeys: String, CodingKey {
        case name, apps, steps
        case continueOnFailure = "continue_on_failure"
        case cleanupSteps = "cleanup_steps"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        apps = try container.decode([String: String].self, forKey: .apps)
        steps = try container.decode([Step].self, forKey: .steps)
        continueOnFailure = try container.decodeIfPresent(Bool.self, forKey: .continueOnFailure) ?? false
        cleanupSteps = try container.decodeIfPresent([Step].self, forKey: .cleanupSteps) ?? []
    }

    struct Step: Decodable {
        let action: String
        let app: String?
        let name: String?
        let identifier: String?
        let identifiersValue: [String]?
        let label: String?
        let labelsValue: [String]?
        let containsText: String?
        let containsTextsValue: [String]?
        let elementType: String?
        let elementTypesValue: [String]?
        let text: String?
        let preferredValues: [String]
        let expectedTexts: [String]
        let failureTexts: [String]
        let authTexts: [String]
        let loadingTexts: [String]
        let loadingIdentifiers: [String]
        let minimumElements: Int?
        let minimumBytes: Int?
        let minimumBytesPerSecond: Double?
        let rangeBytes: Int?
        let maximumAssets: Int?
        let minimumSuccessfulAssets: Int?
        let minimumAssetBytes: Int?
        let assetReadLimitBytes: Int?
        let concurrency: Int?
        let allowSiteChallenge: Bool?
        let expectedSuccess: Bool?
        let cacheBust: Bool?
        let section: String?
        let group: String?
        let outbound: String?
        let fatal: Bool
        let x: CGFloat?
        let y: CGFloat?
        let endX: CGFloat?
        let endY: CGFloat?
        let seconds: TimeInterval?
        let timeout: TimeInterval?
        let duration: TimeInterval?
        let holdDuration: TimeInterval?
        let endHoldDuration: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case action, app, name, identifier, label, text, group, outbound, fatal, x, y, seconds, timeout, duration
            case identifiersValue = "identifiers"
            case labelsValue = "labels"
            case containsText = "contains_text"
            case containsTextsValue = "contains_texts"
            case elementType = "element_type"
            case elementTypesValue = "element_types"
            case preferredValues = "preferred_values"
            case expectedTexts = "expected_texts"
            case failureTexts = "failure_texts"
            case authTexts = "auth_texts"
            case loadingTexts = "loading_texts"
            case loadingIdentifiers = "loading_identifiers"
            case minimumElements = "minimum_elements"
            case minimumBytes = "minimum_bytes"
            case minimumBytesPerSecond = "minimum_bytes_per_second"
            case rangeBytes = "range_bytes"
            case maximumAssets = "maximum_assets"
            case minimumSuccessfulAssets = "minimum_successful_assets"
            case minimumAssetBytes = "minimum_asset_bytes"
            case assetReadLimitBytes = "asset_read_limit_bytes"
            case concurrency
            case allowSiteChallenge = "allow_site_challenge"
            case expectedSuccess = "expected_success"
            case cacheBust = "cache_bust"
            case section
            case endX = "end_x"
            case endY = "end_y"
            case holdDuration = "hold_duration"
            case endHoldDuration = "end_hold_duration"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            app = try container.decodeIfPresent(String.self, forKey: .app)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            identifiersValue = try container.decodeIfPresent([String].self, forKey: .identifiersValue)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            labelsValue = try container.decodeIfPresent([String].self, forKey: .labelsValue)
            containsText = try container.decodeIfPresent(String.self, forKey: .containsText)
            containsTextsValue = try container.decodeIfPresent([String].self, forKey: .containsTextsValue)
            elementType = try container.decodeIfPresent(String.self, forKey: .elementType)
            elementTypesValue = try container.decodeIfPresent([String].self, forKey: .elementTypesValue)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            preferredValues = try container.decodeIfPresent([String].self, forKey: .preferredValues) ?? []
            expectedTexts = try container.decodeIfPresent([String].self, forKey: .expectedTexts) ?? []
            failureTexts = try container.decodeIfPresent([String].self, forKey: .failureTexts) ?? []
            authTexts = try container.decodeIfPresent([String].self, forKey: .authTexts) ?? []
            loadingTexts = try container.decodeIfPresent([String].self, forKey: .loadingTexts) ?? []
            loadingIdentifiers = try container.decodeIfPresent([String].self, forKey: .loadingIdentifiers) ?? []
            minimumElements = try container.decodeIfPresent(Int.self, forKey: .minimumElements)
            minimumBytes = try container.decodeIfPresent(Int.self, forKey: .minimumBytes)
            minimumBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .minimumBytesPerSecond)
            rangeBytes = try container.decodeIfPresent(Int.self, forKey: .rangeBytes)
            maximumAssets = try container.decodeIfPresent(Int.self, forKey: .maximumAssets)
            minimumSuccessfulAssets = try container.decodeIfPresent(Int.self, forKey: .minimumSuccessfulAssets)
            minimumAssetBytes = try container.decodeIfPresent(Int.self, forKey: .minimumAssetBytes)
            assetReadLimitBytes = try container.decodeIfPresent(Int.self, forKey: .assetReadLimitBytes)
            concurrency = try container.decodeIfPresent(Int.self, forKey: .concurrency)
            allowSiteChallenge = try container.decodeIfPresent(Bool.self, forKey: .allowSiteChallenge)
            expectedSuccess = try container.decodeIfPresent(Bool.self, forKey: .expectedSuccess)
            cacheBust = try container.decodeIfPresent(Bool.self, forKey: .cacheBust)
            section = try container.decodeIfPresent(String.self, forKey: .section)
            group = try container.decodeIfPresent(String.self, forKey: .group)
            outbound = try container.decodeIfPresent(String.self, forKey: .outbound)
            fatal = try container.decodeIfPresent(Bool.self, forKey: .fatal) ?? false
            x = try container.decodeIfPresent(CGFloat.self, forKey: .x)
            y = try container.decodeIfPresent(CGFloat.self, forKey: .y)
            endX = try container.decodeIfPresent(CGFloat.self, forKey: .endX)
            endY = try container.decodeIfPresent(CGFloat.self, forKey: .endY)
            seconds = try container.decodeIfPresent(TimeInterval.self, forKey: .seconds)
            timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout)
            duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            holdDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .holdDuration)
            endHoldDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .endHoldDuration)
        }

        private init(action: String, identifiers: [String]) {
            self.action = action
            app = nil
            name = nil
            identifier = nil
            identifiersValue = identifiers
            label = nil
            labelsValue = nil
            containsText = nil
            containsTextsValue = nil
            elementType = nil
            elementTypesValue = nil
            text = nil
            preferredValues = []
            expectedTexts = []
            failureTexts = []
            authTexts = []
            loadingTexts = []
            loadingIdentifiers = []
            minimumElements = nil
            minimumBytes = nil
            minimumBytesPerSecond = nil
            rangeBytes = nil
            maximumAssets = nil
            minimumSuccessfulAssets = nil
            minimumAssetBytes = nil
            assetReadLimitBytes = nil
            concurrency = nil
            allowSiteChallenge = nil
            expectedSuccess = nil
            cacheBust = nil
            section = nil
            group = nil
            outbound = nil
            fatal = false
            x = nil
            y = nil
            endX = nil
            endY = nil
            seconds = nil
            timeout = nil
            duration = nil
            holdDuration = nil
            endHoldDuration = nil
        }

        static func lookup(identifiers: [String]) -> Step {
            Step(action: "lookup", identifiers: identifiers)
        }

        var identifiers: [String] {
            ([identifier].compactMap { $0 }) + (identifiersValue ?? [])
        }

        var labels: [String] {
            ([label].compactMap { $0 }) + (labelsValue ?? [])
        }

        var containsTexts: [String] {
            ([containsText].compactMap { $0 }) + (containsTextsValue ?? [])
        }

        var elementTypes: [String] {
            ([elementType].compactMap { $0 }) + (elementTypesValue ?? [])
        }

        var elementSummary: String {
            (identifiers + labels + containsTexts + elementTypes).joined(separator: ", ")
        }

        var summary: String {
            [action, app, identifier, label, name, group, outbound].compactMap { $0 }.joined(separator: " ")
        }
    }

    static func load() throws -> DeviceScenario {
        let environment = ProcessInfo.processInfo.environment
        if let encoded = environment["WLT_DEVICE_SCENARIO_BASE64"], let data = Data(base64Encoded: encoded) {
            return try JSONDecoder().decode(DeviceScenario.self, from: data)
        }
        guard let url = Bundle(for: DeviceScenarioTests.self).url(forResource: "wlt-mobile", withExtension: "json") else {
            throw ScenarioError.failed("wlt-mobile.json is missing from the UI-test bundle")
        }
        return try JSONDecoder().decode(DeviceScenario.self, from: Data(contentsOf: url))
    }
}

private enum ScenarioError: LocalizedError {
    case invalidStep(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidStep(message), let .failed(message): message
        }
    }
}
