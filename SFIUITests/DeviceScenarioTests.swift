import XCTest
import UIKit

@MainActor
final class DeviceScenarioTests: XCTestCase {
    private var scenario: DeviceScenario!
    private var apps: [String: XCUIApplication] = [:]
    private var skippedApps: Set<String> = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        scenario = try DeviceScenario.load()
        apps["vpn"] = XCUIApplication()
        for (name, bundleIdentifier) in scenario.apps where name != "vpn" {
            apps[name] = XCUIApplication(bundleIdentifier: bundleIdentifier)
        }
        apps["vpn"]?.launchEnvironment["WLT_DEVICE_SCENARIO"] = "1"
    }

    override func tearDownWithError() throws {
        defer {
            apps.removeAll()
            skippedApps.removeAll()
            scenario = nil
        }
        guard let vpnApp = apps["vpn"] else { return }
        vpnApp.activate()
        guard vpnApp.staticTexts["Started"].firstMatch.waitForExistence(timeout: 3) else { return }
        let toggle = vpnApp.descendants(matching: .any).matching(identifier: "wlt.connection.toggle").firstMatch
        guard toggle.waitForExistence(timeout: 3) else { return }
        toggle.tap()
        _ = vpnApp.staticTexts["Stopped"].firstMatch.waitForExistence(timeout: 30)
        attachScreenshot(named: "vpn-teardown-stopped")
    }

    func testScenario() throws {
        XCTContext.runActivity(named: scenario.name) { _ in
            for (index, step) in scenario.steps.enumerated() {
                XCTContext.runActivity(named: String(format: "%03d %@", index + 1, step.summary)) { _ in
                    do {
                        try execute(step)
                    } catch {
                        attachScreenshot(named: String(format: "failure-%03d", index + 1))
                        XCTFail("Step \(index + 1) failed: \(step.summary): \(error)")
                    }
                }
            }
        }
    }

    func testCrossAppProof() throws {
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
        let appName = step.app ?? "vpn"
        let app = application(named: appName)
        let timeout = step.timeout ?? 20

        if skippedApps.contains(appName) {
            return
        }

        switch step.action {
        case "launch":
            app.launch()
            try require(app.wait(for: .runningForeground, timeout: timeout), "app did not enter foreground")
        case "launch_if_installed":
            app.launch()
            guard app.wait(for: .runningForeground, timeout: timeout) else {
                skippedApps.insert(appName)
                attachScreenshot(named: step.name ?? "\(appName)-not-available")
                return
            }
        case "activate":
            app.activate()
            try require(app.wait(for: .runningForeground, timeout: timeout), "app did not enter foreground")
        case "terminate":
            app.terminate()
        case "home":
            XCUIDevice.shared.press(.home)
        case "wait":
            Thread.sleep(forTimeInterval: step.seconds ?? 1)
        case "tap":
            try coordinate(step, in: app).tap()
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
            start.press(forDuration: step.holdDuration ?? 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: step.endHoldDuration ?? 0)
        case "tap_element":
            try findElement(step, in: app, timeout: timeout).tap()
        case "tap_if_text":
            guard let text = step.text else { throw ScenarioError.invalidStep("tap_if_text requires text") }
            if app.staticTexts[text].firstMatch.exists {
                try findElement(step, in: app, timeout: timeout).tap()
            }
        case "tap_text":
            guard let text = step.text else { throw ScenarioError.invalidStep("tap_text requires text") }
            try textElement(text, in: app, timeout: timeout).tap()
        case "tap_text_if_present":
            guard let text = step.text else { throw ScenarioError.invalidStep("tap_text_if_present requires text") }
            let element = try textElement(text, in: app, timeout: min(timeout, 1), required: false)
            if element.exists { element.tap() }
        case "tap_text_any_if_present":
            guard let texts = step.texts, !texts.isEmpty else {
                throw ScenarioError.invalidStep("tap_text_any_if_present requires texts")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let element = texts.lazy
                    .map({ textElement($0, in: app, timeout: 0, required: false) })
                    .first(where: \.exists)
                {
                    element.tap()
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
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
        case "type_into":
            guard let text = step.text else { throw ScenarioError.invalidStep("type_into requires text") }
            let element = try findElement(step, in: app, timeout: timeout)
            element.tap()
            for _ in 0 ..< 2 where !app.keyboards.firstMatch.exists {
                Thread.sleep(forTimeInterval: 0.5)
                element.tap()
            }
            try require(app.keyboards.firstMatch.waitForExistence(timeout: 2), "element did not open the software keyboard")
            app.typeText(text)
        case "wait_element":
            _ = try findElement(step, in: app, timeout: timeout)
        case "wait_text":
            guard let text = step.text else { throw ScenarioError.invalidStep("wait_text requires text") }
            _ = try textElement(text, in: app, timeout: timeout)
        case "wait_text_absent":
            guard let text = step.text else { throw ScenarioError.invalidStep("wait_text_absent requires text") }
            let element = try textElement(text, in: app, timeout: 0, required: false)
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
            let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
            try require(result == .completed, "text did not disappear: \(text)")
        case "wait_text_if_present":
            guard let text = step.text else { throw ScenarioError.invalidStep("wait_text_if_present requires text") }
            _ = try textElement(text, in: app, timeout: min(timeout, 1), required: false)
        case "assert_text":
            guard let text = step.text else { throw ScenarioError.invalidStep("assert_text requires text") }
            let element = app.staticTexts[text].firstMatch
            try require(element.waitForExistence(timeout: timeout), "text not found: \(text)")
        case "assert_text_absent":
            guard let text = step.text else { throw ScenarioError.invalidStep("assert_text_absent requires text") }
            let element = app.staticTexts[text].firstMatch
            try require(!element.waitForExistence(timeout: timeout), "unexpected text found: \(text)")
        case "assert_text_any":
            guard let texts = step.texts, !texts.isEmpty else {
                throw ScenarioError.invalidStep("assert_text_any requires texts")
            }
            try require(
                texts.contains(where: { textElement($0, in: app, timeout: 0, required: false).exists }),
                "none of the expected texts are visible"
            )
        case "assert_texts_absent":
            guard let texts = step.texts, !texts.isEmpty else {
                throw ScenarioError.invalidStep("assert_texts_absent requires texts")
            }
            for text in texts {
                let element = textElement(text, in: app, timeout: 0, required: false)
                try require(!element.waitForExistence(timeout: timeout), "unexpected text found: \(text)")
            }
        case "assert_visual_change":
            let before = XCUIScreen.main.screenshot()
            Thread.sleep(forTimeInterval: step.seconds ?? 5)
            let after = XCUIScreen.main.screenshot()
            let ratio = changedPixelRatio(before.image, after.image)
            let minimum = step.minimumChangedRatio ?? 0.015
            let beforeAttachment = XCTAttachment(screenshot: before)
            beforeAttachment.name = "\(step.name ?? "visual-change")-before"
            beforeAttachment.lifetime = .keepAlways
            add(beforeAttachment)
            let afterAttachment = XCTAttachment(screenshot: after)
            afterAttachment.name = "\(step.name ?? "visual-change")-after"
            afterAttachment.lifetime = .keepAlways
            add(afterAttachment)
            try require(ratio >= minimum, "visual content remained static: changed_ratio=\(ratio)")
        case "screenshot":
            attachScreenshot(named: step.name ?? "scenario")
        case "dump_ui":
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = step.name ?? "ui-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        default:
            throw ScenarioError.invalidStep("unknown action: \(step.action)")
        }
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

    private func findElement(_ step: DeviceScenario.Step, in app: XCUIApplication, timeout: TimeInterval) throws -> XCUIElement {
        let element: XCUIElement
        if let identifier = step.identifier {
            element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        } else if let label = step.label {
            element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        } else {
            throw ScenarioError.invalidStep("element action requires identifier or label")
        }
        try require(element.waitForExistence(timeout: timeout), "element not found")
        return element
    }

    private func textElement(
        _ text: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        required: Bool = true
    ) throws -> XCUIElement {
        let predicate = NSPredicate(
            format: "label == %@ OR label CONTAINS %@ OR value == %@ OR value CONTAINS %@",
            text,
            text,
            text,
            text
        )
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        if required {
            try require(element.waitForExistence(timeout: timeout), "text not found: \(text)")
        }
        return element
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ScenarioError.failed(message) }
    }

    private func changedPixelRatio(_ before: UIImage, _ after: UIImage, stride: Int = 8) -> Double {
        guard
            let beforeImage = before.cgImage,
            let afterImage = after.cgImage,
            beforeImage.width == afterImage.width,
            beforeImage.height == afterImage.height
        else {
            return 1
        }
        let width = beforeImage.width
        let height = beforeImage.height
        let bytesPerRow = width * 4
        var beforePixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var afterPixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let beforeContext = CGContext(
                data: &beforePixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let afterContext = CGContext(
                data: &afterPixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return 0
        }
        beforeContext.draw(beforeImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        afterContext.draw(afterImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sampled = 0
        var changed = 0
        for y in Swift.stride(from: 0, to: height, by: max(1, stride)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, stride)) {
                sampled += 1
                let offset = y * bytesPerRow + x * 4
                let delta = abs(Int(beforePixels[offset]) - Int(afterPixels[offset]))
                    + abs(Int(beforePixels[offset + 1]) - Int(afterPixels[offset + 1]))
                    + abs(Int(beforePixels[offset + 2]) - Int(afterPixels[offset + 2]))
                if delta >= 48 {
                    changed += 1
                }
            }
        }
        return sampled == 0 ? 0 : Double(changed) / Double(sampled)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct DeviceScenario: Decodable {
    let name: String
    let apps: [String: String]
    let steps: [Step]

    struct Step: Decodable {
        let action: String
        let app: String?
        let name: String?
        let identifier: String?
        let label: String?
        let text: String?
        let texts: [String]?
        let x: CGFloat?
        let y: CGFloat?
        let endX: CGFloat?
        let endY: CGFloat?
        let seconds: TimeInterval?
        let timeout: TimeInterval?
        let duration: TimeInterval?
        let holdDuration: TimeInterval?
        let endHoldDuration: TimeInterval?
        let minimumChangedRatio: Double?

        enum CodingKeys: String, CodingKey {
            case action, app, name, identifier, label, text, texts, x, y, seconds, timeout, duration
            case endX = "end_x"
            case endY = "end_y"
            case holdDuration = "hold_duration"
            case endHoldDuration = "end_hold_duration"
            case minimumChangedRatio = "minimum_changed_ratio"
        }

        var summary: String {
            [action, app, identifier, label, name].compactMap { $0 }.joined(separator: " ")
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
