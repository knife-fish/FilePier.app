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

        let logsURL = remoteURL.appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try "remote fixture".write(
            to: logsURL.appendingPathComponent("latest.log", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }
}
