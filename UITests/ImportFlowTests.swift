import XCTest

final class ImportFlowTests: XCTestCase {
    private enum PickerFailure: Error { case missing(String) }

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false {
            MainActor.assumeIsolated {
                let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                image.name = "Picker failure screenshot"
                image.lifetime = .keepAlways
                add(image)
                let app = XCUIApplication()
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let tree = "APP\n" + (app.state == .notRunning ? "not running" : app.debugDescription)
                    + "\nSPRINGBOARD\n" + springboard.debugDescription
                let attachment = XCTAttachment(string: tree)
                attachment.name = "Picker failure accessibility trees"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testSystemPickerImportsTXTJSONAndReopensAfterCancel() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--moxu-picker-ui-test"]
        app.launch()
        try importThroughPicker("PickerNovel.txt", title: "PickerNovel", app: app)
        try importThroughPicker("PickerChapters.json", title: "PickerChapters", app: app)

        try openPicker(app)
        let cancel = try requiredNamedElement(["Cancel", "取消"], app: app, timeout: 10)
        cancel.tap()
        try require(waitForHittable(importButton(app), timeout: 10), "取消后导入按钮未恢复")
        // The previous notice is JSON, so a stale success label cannot satisfy this TXT import.
        try importThroughPicker("PickerNovel.txt", title: "PickerNovel", app: app)
    }

    @MainActor
    private func importThroughPicker(_ filename: String, title: String, app: XCUIApplication) throws {
        try openPicker(app)
        let stem = (filename as NSString).deletingPathExtension
        var file: XCUIElement?
        for _ in 0..<18 {
            if let found = namedElement([filename, stem], app: app) { file = found; break }
            // directoryURL is a hint; a fresh Files provider can start in Recents instead.
            var navigated = false
            for names in [["PickerUI"], ["墨序", "Moxu"],
                          ["On My iPhone", "我的 iPhone", "在我的 iPhone", "我的iPhone"],
                          ["Browse", "浏览", "瀏覽"], ["Continue", "继续"]] {
                if let element = namedElement(names, app: app) {
                    element.tap()
                    navigated = true
                    break
                }
            }
            if !navigated { app.swipeDown() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let file else { throw PickerFailure.missing("系统文件选择器未找到 \(filename)") }
        screenshot("System picker selecting \(filename)")
        file.tap()
        let notice = app.descendants(matching: .any).matching(identifier: "import-success").firstMatch
        // Some provider presentations use selection + Open instead of opening on the first tap.
        if !notice.waitForExistence(timeout: 2) || !notice.label.contains(title) {
            if let confirm = namedElement(["Open", "打开", "開啟"], app: app) { confirm.tap() }
        }
        let success = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", title), object: notice)
        try require(XCTWaiter.wait(for: [success], timeout: 20) == .completed,
                    "选取 \(filename) 后未收到对应导入成功反馈")
        var book = app.staticTexts[title].firstMatch
        for _ in 0..<8 {
            if book.exists && book.isHittable { break }
            app.swipeUp()
            book = app.staticTexts[title].firstMatch
        }
        try require(book.exists && book.isHittable, "书架未显示新导入的 \(title)")
        screenshot("Imported bookshelf \(title)")
    }

    @MainActor
    private func openPicker(_ app: XCUIApplication) throws {
        let button = importButton(app)
        try require(waitForHittable(button, timeout: 15), "未找到可操作的小说导入按钮")
        button.tap()
        _ = try requiredNamedElement(["Cancel", "取消"], app: app, timeout: 15)
    }

    @MainActor
    private func importButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "novel-import-button").firstMatch
    }

    @MainActor
    private func namedElement(_ names: [String], app: XCUIApplication) -> XCUIElement? {
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: names.map {
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                        $0, $0 + ",", $0 + "\n", $0 + " ")
        })
        // Real UIDocumentPicker remote views normally appear in the presenting app's tree.
        for root in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            for type in [XCUIElement.ElementType.cell, .button, .staticText, .other] {
                let candidates = root.descendants(matching: type).matching(predicate)
                for candidate in candidates.allElementsBoundByIndex where candidate.exists && candidate.isHittable {
                    return candidate
                }
            }
        }
        return nil
    }

    @MainActor
    private func requiredNamedElement(_ names: [String], app: XCUIApplication, timeout: TimeInterval) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = namedElement(names, app: app) { return element }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        throw PickerFailure.missing("未找到系统选择器控件：\(names.joined(separator: "/"))")
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in element.exists && element.isHittable }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PickerFailure.missing(message) }
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
