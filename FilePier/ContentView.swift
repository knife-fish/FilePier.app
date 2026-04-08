import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var state: FilePierWorkspaceState

    init() {
        _state = StateObject(wrappedValue: Self.makeInitialState())
    }

    var body: some View {
        FilePierWorkspaceView(state: state)
    }

    private static func makeInitialState() -> FilePierWorkspaceState {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("--ui-testing-fixture") else {
            return FilePierWorkspaceState()
        }

        let environment = processInfo.environment
        let fileManager = FileManager.default
        let localRoot = environment["FILEPIER_UI_LOCAL_ROOT"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory.appendingPathComponent("FilePierUITests/Local", isDirectory: true)
        let remoteRoot = environment["FILEPIER_UI_REMOTE_ROOT"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory.appendingPathComponent("FilePierUITests/Remote", isDirectory: true)
        let stateRoot = environment["FILEPIER_UI_STATE_ROOT"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory.appendingPathComponent("FilePierUITests/State", isDirectory: true)

        try? fileManager.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        return FilePierWorkspaceState(
            localFileBrowser: LocalFileBrowserService(),
            localFileTransfer: LocalFileTransferService(),
            savedServerStore: JSONSavedServerStore(
                fileURL: stateRoot.appendingPathComponent("SavedServers.json", isDirectory: false)
            ),
            favoritePlaceStore: JSONFavoritePlaceStore(
                fileURL: stateRoot.appendingPathComponent("FavoritePlaces.json", isDirectory: false)
            ),
            workspacePreferenceStore: JSONWorkspacePreferenceStore(
                fileURL: stateRoot.appendingPathComponent("WorkspacePreferences.json", isDirectory: false)
            ),
            siteUsageStore: JSONSiteUsageStore(
                fileURL: stateRoot.appendingPathComponent("SiteUsage.json", isDirectory: false)
            ),
            credentialStore: InMemoryServerCredentialStore(),
            initialLocalDirectoryURL: localRoot,
            initialRemoteDirectoryURL: remoteRoot
        )
    }
}

#Preview {
    ContentView()
}
