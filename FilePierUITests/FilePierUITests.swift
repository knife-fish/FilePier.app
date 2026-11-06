import XCTest

final class FilePierUITests: XCTestCase {
    private var fixtureRootURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try prepareFixtureTree(at: fixtureRootURL)
    }

    override func tearDownWithError() throws {
        if let fixtureRootURL {
            try? FileManager.default.removeItem(at: fixtureRootURL)
        }
        fixtureRootURL = nil
    }

    @MainActor
    func testWorkspaceAppearsOnLaunch() throws {
        let app = makeFixtureApplication()
        app.launch()

        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Readme.md"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Logs"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCommandClickKeepsMultipleFilesSelectedInBothPanes() throws {
        try assertAdditiveSelection(using: .command)
    }

    @MainActor
    func testControlClickKeepsMultipleFilesSelectedInBothPanes() throws {
        try assertAdditiveSelection(using: .control)
    }

    @MainActor
    private func assertAdditiveSelection(using modifier: XCUIElement.KeyModifierFlags) throws {
        let app = makeFixtureApplication()
        app.launch()

        for (pane, names) in [
            ("local-browser-list", ["Readme.md", "Second.txt", "Third.txt"]),
            ("remote-browser-list", ["First.log", "Second.log", "Third.log"])
        ] {
            let list = app.descendants(matching: .any).matching(identifier: pane).firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            let first = list.outlineRows.containing(.staticText, identifier: names[0]).firstMatch
            let second = list.outlineRows.containing(.staticText, identifier: names[1]).firstMatch
            let third = list.outlineRows.containing(.staticText, identifier: names[2]).firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            list.staticTexts[names[0]].click()
            XCUIElement.perform(withKeyModifiers: modifier) { list.staticTexts[names[1]].click() }
            XCTAssertTrue(first.isSelected, "The first file must remain selected in \(pane).")
            XCTAssertTrue(second.isSelected, "The added file must stay selected after mouse-up in \(pane).")

            XCUIElement.perform(withKeyModifiers: modifier) { list.staticTexts[names[2]].click() }
            XCTAssertTrue(first.isSelected && second.isSelected && third.isSelected)
            XCUIElement.perform(withKeyModifiers: modifier) { list.staticTexts[names[1]].click() }
            XCTAssertTrue(first.isSelected && third.isSelected)
            XCTAssertFalse(second.isSelected, "A modifier-click on a selected file must deselect it.")

            list.staticTexts[names[1]].click()
            XCTAssertTrue(second.isSelected)
            XCTAssertFalse(first.isSelected || third.isSelected, "A plain click must return to single selection.")
        }
    }

    @MainActor
    func testShiftClickSelectsRangeAndRightClickPreservesSelection() throws {
        let app = makeFixtureApplication()
        app.launch()

        for (pane, names) in [
            ("local-browser-list", ["Readme.md", "Second.txt", "Third.txt"]),
            ("remote-browser-list", ["First.log", "Second.log", "Third.log"])
        ] {
            let list = app.descendants(matching: .any).matching(identifier: pane).firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            list.staticTexts[names[0]].click()
            XCUIElement.perform(withKeyModifiers: .shift) { list.staticTexts[names[2]].click() }
            for name in names {
                XCTAssertTrue(list.outlineRows.containing(.staticText, identifier: name).firstMatch.isSelected)
            }

            list.staticTexts[names[0]].rightClick()
            XCTAssertTrue(app.menus.firstMatch.waitForExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
            for name in names {
                XCTAssertTrue(list.outlineRows.containing(.staticText, identifier: name).firstMatch.isSelected,
                    "Opening a context menu must retain the selection in \(pane).")
            }
        }
    }

    @MainActor
    func testDoubleClickStillOpensFolder() throws {
        let app = makeFixtureApplication()
        app.launch()
        let list = app.descendants(matching: .any).matching(identifier: "remote-browser-list").firstMatch
        XCTAssertTrue(list.staticTexts["Logs"].waitForExistence(timeout: 5))
        list.staticTexts["Logs"].doubleClick()
        XCTAssertTrue(list.staticTexts["latest.log"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        throw XCTSkip("Launch performance measurement is flaky in macOS UI automation because the app does not terminate reliably between iterations.")
    }

    private func makeFixtureApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing-fixture"]
        app.launchEnvironment["FILEPIER_UI_LOCAL_ROOT"] = fixtureRootURL
            .appendingPathComponent("Local", isDirectory: true)
            .path(percentEncoded: false)
        app.launchEnvironment["FILEPIER_UI_REMOTE_ROOT"] = fixtureRootURL
            .appendingPathComponent("Remote", isDirectory: true)
            .path(percentEncoded: false)
        app.launchEnvironment["FILEPIER_UI_STATE_ROOT"] = fixtureRootURL
            .appendingPathComponent("State", isDirectory: true)
            .path(percentEncoded: false)
        return app
    }

    private func prepareFixtureTree(at rootURL: URL) throws {
        let fileManager = FileManager.default
        let localURL = rootURL.appendingPathComponent("Local", isDirectory: true)
        let remoteURL = rootURL.appendingPathComponent("Remote", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("State", isDirectory: true)

        try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: remoteURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateURL, withIntermediateDirectories: true)

        try "fixture".write(
            to: localURL.appendingPathComponent("Readme.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        for name in ["Second.txt", "Third.txt"] {
            try "fixture".write(to: localURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for name in ["First.log", "Second.log", "Third.log"] {
            try "remote fixture".write(to: remoteURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let logsURL = remoteURL.appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try "remote fixture".write(
            to: logsURL.appendingPathComponent("latest.log", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }
}
