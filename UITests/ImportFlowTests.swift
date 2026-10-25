import XCTest
import UIKit

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
    func testPasteNovelImport() throws {
        executionTimeAllowance = 120
        let copiedNovel = "序章\n林舟推开书店的门。原文与 emoji 🙂 应完整导入。"
        UIPasteboard.general.string = copiedNovel
        let app = XCUIApplication()
        app.launchArguments = ["--moxu-picker-ui-test"]
        app.launch()
        let projectCount = app.descendants(matching: .any).matching(identifier: "project-count").firstMatch
        try require(projectCount.waitForExistence(timeout: 15), "粘贴前未找到书架作品数量")
        let previousCount = projectCount.label
        let entry = app.buttons.matching(identifier: "novel-paste-button").firstMatch
        try require(waitForHittable(entry, timeout: 15), "未找到粘贴小说入口")
        entry.tap()
        let title = app.textFields.matching(identifier: "novel-paste-title").firstMatch
        try require(waitForHittable(title, timeout: 10), "未找到粘贴小说书名输入框")
        title.tap()
        title.typeText("PasteNovel\n")
        let paste = app.buttons.matching(identifier: "novel-paste-insert").firstMatch
        try require(waitForHittable(paste, timeout: 10), "未找到系统 PasteButton")
        UIPasteboard.general.string = copiedNovel
        screenshot("PasteButton before visible control tap")
        // Form can expose a full-width AX row while the actual colored PasteButton stays on the left.
        // Hit the visible control rather than the accessibility row's empty geometric center.
        paste.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: min(50, paste.frame.width / 2), dy: paste.frame.height / 2)
        ).tap()
        let confirm = app.buttons.matching(identifier: "novel-paste-confirm").firstMatch
        try require(waitForHittable(confirm, timeout: 10), "粘贴后未找到导入确认按钮")
        confirm.tap()
        let notice = app.descendants(matching: .any).matching(identifier: "import-success").firstMatch
        let success = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "PasteNovel"), object: notice)
        let addedProject = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label != %@", previousCount), object: projectCount)
        try require(XCTWaiter.wait(for: [success, addedProject], timeout: 20) == .completed,
                    "真正 PasteButton 导入后未收到成功提示及作品数量变化")
        var book = app.staticTexts["PasteNovel"].firstMatch
        for _ in 0..<8 {
            if book.exists && book.isHittable { break }
            app.swipeUp()
            book = app.staticTexts["PasteNovel"].firstMatch
        }
        try require(book.exists && book.isHittable, "书架未显示粘贴导入的 PasteNovel")
        screenshot("PasteButton imported bookshelf PasteNovel")
    }

    @MainActor
    func testSystemPickerImportsTXTJSONAndReopensAfterCancel() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--moxu-picker-ui-test"]
        app.launch()
        try importThroughPicker("PickerChapters.json", title: "PickerChapters", app: app)
        try importThroughPicker("PickerNovel.txt", title: "PickerNovel", app: app)

        try openPicker(app)
        let cancel = try requiredNamedElement(["Cancel", "取消"], app: app, timeout: 10)
        cancel.tap()
        try require(waitForHittable(importButton(app), timeout: 10), "取消后导入按钮未恢复")
        // The prior notice is also TXT; every import must independently increase the bookshelf count.
        try importThroughPicker("PickerNovel.txt", title: "PickerNovel", app: app)
    }

    @MainActor
    private func importThroughPicker(_ filename: String, title: String, app: XCUIApplication) throws {
        let projectCount = app.descendants(matching: .any).matching(identifier: "project-count").firstMatch
        try require(projectCount.waitForExistence(timeout: 15), "未找到书架作品数量")
        let previousCount = projectCount.label
        try openPicker(app)
        let stem = (filename as NSString).deletingPathExtension
        var file: XCUIElement?
        for _ in 0..<18 {
            // A matching filename in Recents or this app's own Documents is not sufficient.
            // Only select after navigating into the host-created external Downloads fixture folder.
            if externalFolderIsOpen(app) {
                if let found = namedElement([filename, stem], app: app) { file = found; break }
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            var navigated = false
            for names in [["MoxuImportUI"], ["Downloads", "下载项目", "下載項目", "下载", "下載"],
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
        guard let file else { throw PickerFailure.missing("系统文件选择器未在外部 Downloads/MoxuImportUI 找到 \(filename)") }
        try require(file.isEnabled, "系统选择器中的 \(filename) 不可用，请确认文件已下载。")
        screenshot("External Downloads system picker selecting \(filename)")
        let filenameLabel = file.descendants(matching: .staticText).matching(
            NSPredicate(format: "label == %@ OR label == %@", filename, stem)).firstMatch
        if filenameLabel.exists && filenameLabel.isHittable {
            filenameLabel.tap()
        } else {
            file.tap()
        }
        let notice = app.descendants(matching: .any).matching(identifier: "import-success").firstMatch
        // Some provider presentations use selection + Open instead of opening on the first tap.
        if !notice.waitForExistence(timeout: 2) || !notice.label.contains(title) || projectCount.label == previousCount {
            if let confirm = namedElement(["Open", "打开", "開啟"], app: app) { confirm.tap() }
        }
        let success = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", title), object: notice)
        let addedProject = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label != %@", previousCount), object: projectCount)
        try require(XCTWaiter.wait(for: [success, addedProject], timeout: 20) == .completed,
                    "选取 \(filename) 后未同时收到对应成功反馈和新增作品数量；导入前：\(previousCount)")
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
    private func externalFolderIsOpen(_ app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "MoxuImportUI", "MoxuImportUI,")
        return app.navigationBars.descendants(matching: .any).matching(predicate).firstMatch.exists
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
        let predicate = NSPredicate { _, _ in element.exists && element.isHittable && element.isEnabled }
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
