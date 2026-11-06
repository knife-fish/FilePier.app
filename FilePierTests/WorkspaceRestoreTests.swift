import Foundation
import Testing
@testable import FilePier

@MainActor
struct WorkspaceRestoreTests {
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for restored workspace or transfer.")
    }

    @Test func olderPreferencesRemainReadable() throws {
        let preferences = try JSONDecoder().decode(WorkspacePreferences.self, from: Data("{\"showsInspector\":false}".utf8))
        #expect(!preferences.showsInspector)
        #expect(preferences.localBrowserSort == .default)
        #expect(preferences.remoteBrowserSort == .default)
        #expect(preferences.lastLocalDirectory == nil)
        #expect(preferences.serverWorkspaces.isEmpty)
    }

    @Test func directoriesAndSortsRestorePerSiteAcrossLaunches() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.removeFiles() }
        let localChild = fixture.local.appendingPathComponent("Work", isDirectory: true)
        let remoteChild = fixture.remote.appendingPathComponent("Inbox", isDirectory: true)
        for folder in [localChild, remoteChild] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "a".write(to: folder.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
            try "zz".write(to: folder.appendingPathComponent("zeta.txt"), atomically: true, encoding: .utf8)
        }
        let descending = BrowserSortOption(field: .name, ascending: false)
        let first = fixture.makeState()
        first.connectRemoteSession()
        try await waitUntil { first.isRemoteConnected }
        first.selectLocalItem(id: try #require(first.localItems.first { $0.name == "Work" }?.id))
        first.openLocalSelection()
        first.navigateToRemotePath(remoteChild.path)
        try await waitUntil { first.remoteItems.contains { $0.name == "alpha.txt" } }
        first.setBrowserSort(descending, for: .local)
        first.setBrowserSort(descending, for: .remote)

        // Selecting a different site while connected must keep saving to the active site.
        first.selectServer(fixture.otherServer)
        first.setBrowserSort(descending, for: .remote)
        let beforeSwitch = fixture.makeState()
        #expect(beforeSwitch.localDirectoryURL.path == localChild.path)
        first.connectRemoteSession()
        try await waitUntil { first.isRemoteConnected && first.remoteSessionServerID == fixture.otherServer.id }
        first.setBrowserSort(.default, for: .local)
        first.setBrowserSort(.default, for: .remote)

        let second = fixture.makeState()
        #expect(second.selectedServer?.id == fixture.otherServer.id)
        #expect(!second.isRemoteConnected)
        second.selectServer(fixture.server)
        second.connectRemoteSession()
        try await waitUntil { second.isRemoteConnected }
        #expect(second.localDirectoryURL.path == localChild.path)
        #expect(URL(fileURLWithPath: second.remoteLocation.remotePath).path == remoteChild.path)
        #expect(second.localBrowserSort == descending)
        #expect(second.remoteBrowserSort == descending)
        #expect(second.localItems.map(\.name) == ["zeta.txt", "alpha.txt"])
        #expect(second.remoteItems.map(\.name) == ["zeta.txt", "alpha.txt"])
    }

    @Test func missingRememberedDirectoriesFallBackToConfiguredFolders() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.removeFiles() }
        let missing = fixture.root.appendingPathComponent("Removed")
        var preferences = WorkspacePreferences.default
        preferences.lastLocalDirectory = SavedLocalDirectory(url: missing)
        preferences.serverWorkspaces[fixture.server.id] = .init(
            localDirectory: SavedLocalDirectory(url: missing), remotePath: missing.path,
            localBrowserSort: .default, remoteBrowserSort: .default)
        try fixture.preferences.savePreferences(preferences)
        let state = fixture.makeState()
        #expect(state.localDirectoryURL.path == fixture.local.path)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        #expect(state.localDirectoryURL.path == fixture.local.path)
        #expect(URL(fileURLWithPath: state.remoteLocation.remotePath).path == fixture.remote.path)
    }

    @Test(arguments: [true, false])
    func restoredFilesWaitForManualStartAndCorrectSite(upload: Bool) async throws {
        let fixture = try RestoreFixture()
        defer { fixture.removeFiles() }
        let source = (upload ? fixture.local : fixture.remote).appendingPathComponent("payload.txt")
        let destination = (upload ? fixture.remote : fixture.local).appendingPathComponent("payload.txt")
        try "restored content".write(to: source, atomically: true, encoding: .utf8)
        var saved = try fixture.savedTransfer(source: source, upload: upload)
        saved.progress = 0.4
        try fixture.queue.saveTransfers([saved])
        let state = fixture.makeState()
        #expect(state.recentTransfers.count == 1)
        #expect(state.recentTransfers.first?.status == .paused)
        #expect(state.recentTransfers.first?.progress == 0.4)
        #expect(state.canResumeTransferActivity(saved.id))
        state.resumeTransferActivity(saved.id)
        #expect(state.recentTransfers.first?.status == .paused)

        state.selectServer(fixture.otherServer)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        state.resumeTransferActivity(saved.id)
        #expect(state.recentTransfers.first?.status == .paused)
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        state.selectServer(fixture.server)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected && state.remoteSessionServerID == fixture.server.id }
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.recentTransfers.first?.status == .paused)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        state.resumeTransferActivity(saved.id)
        try await waitUntil { state.recentTransfers.contains { $0.id == saved.id && $0.status == .completed } }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "restored content")
        #expect(try fixture.queue.loadTransfers().isEmpty)
        #expect(fixture.makeState().recentTransfers.isEmpty)
    }

    @Test func cancelledRestoredTaskStaysRemovedAndMissingSourceStaysRecoverable() throws {
        let fixture = try RestoreFixture()
        defer { fixture.removeFiles() }
        let source = fixture.local.appendingPathComponent("missing.txt")
        let saved = try fixture.savedTransfer(source: source, upload: true)
        try fixture.queue.saveTransfers([saved])
        let state = fixture.makeState()
        state.remoteSessionStatus = .connected("test")
        state.resumeTransferActivity(saved.id)
        #expect(state.recentTransfers.first?.status == .paused)
        #expect(try fixture.queue.loadTransfers().count == 1)
        #expect(state.canCancelTransferActivity(saved.id))
        state.cancelTransferActivity(saved.id)
        #expect(state.recentTransfers.first?.status == .cancelled)
        #expect(try fixture.queue.loadTransfers().isEmpty)
        #expect(fixture.makeState().recentTransfers.isEmpty)
    }

    @Test(arguments: [true, false])
    func pendingFolderEnumerationReusesAlreadyCreatedDestination(upload: Bool) async throws {
        let fixture = try RestoreFixture()
        defer { fixture.removeFiles() }
        let source = (upload ? fixture.local : fixture.remote).appendingPathComponent("Assets", isDirectory: true)
        let target = (upload ? fixture.remote : fixture.local).appendingPathComponent("Assets 2", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "image".write(to: source.appendingPathComponent("hero.txt"), atomically: true, encoding: .utf8)
        var saved = try fixture.savedTransfer(source: source, upload: upload)
        if upload {
            saved.preparedRemoteDirectory = fixture.client.makeLocation(for: target)
        } else {
            saved.preparedLocalDirectory = target
        }
        try fixture.queue.saveTransfers([saved])
        let state = fixture.makeState()
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        state.resumeTransferActivity(saved.id)
        try await waitUntil { try fixture.queue.loadTransfers().isEmpty }
        #expect(try String(contentsOf: target.appendingPathComponent("hero.txt"), encoding: .utf8) == "image")
        #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent("Assets").path))
    }

    @Test(arguments: [true, false])
    func liveFolderQueueSavesPendingChildrenAndProgress(upload: Bool) async throws {
        let fixture = try RestoreFixture(delay: 0.015)
        defer { fixture.removeFiles() }
        let source = (upload ? fixture.local : fixture.remote).appendingPathComponent("Batch", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("large.bin"))
        let state = fixture.makeState()
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        if upload {
            #expect(state.handleDrop(of: [source], into: .remote))
        } else {
            #expect(state.handleRemoteDrop(of: [.init(id: source.path, name: "Batch", pathDescription: source.path, isDirectory: true)], into: .local))
        }
        // The root is durable before asynchronous enumeration starts.
        #expect(try fixture.queue.loadTransfers().count == 1)
        #expect(try fixture.queue.loadTransfers().first?.isDirectory == true)
        try await waitUntil {
            state.recentTransfers.contains { $0.title == "large.bin" && $0.status == .running && $0.progress > 0 }
        }
        let activity = try #require(state.recentTransfers.first { $0.title == "large.bin" })
        state.pauseTransferActivity(activity.id)
        let snapshot = try fixture.queue.loadTransfers()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.isDirectory == false)
        #expect(snapshot.first?.progress ?? 0 > 0)
        let restoredQueue = JSONTransferQueueStore(fileURL: fixture.root.appendingPathComponent("RestoredQueue.json"))
        try restoredQueue.saveTransfers(snapshot)
        state.cancelTransferActivity(activity.id)
        try await waitUntil { !state.isRemoteBusy }
        #expect(try fixture.queue.loadTransfers().isEmpty)
        let restored = fixture.makeState(queue: restoredQueue)
        #expect(restored.recentTransfers.count == 1)
        #expect(restored.recentTransfers.first?.status == .paused)
        restored.connectRemoteSession()
        try await waitUntil { restored.isRemoteConnected }
        restored.resumeTransferActivity(activity.id)
        try await waitUntil { try restoredQueue.loadTransfers().isEmpty }
        let target = (upload ? fixture.remote : fixture.local).appendingPathComponent("Batch/large.bin")
        #expect(try Data(contentsOf: target).count == 2 * 1024 * 1024)
        #expect(!FileManager.default.fileExists(atPath: (upload ? fixture.remote : fixture.local).appendingPathComponent("Batch 2").path))
    }
}

@MainActor
private struct RestoreFixture {
    let root: URL
    let local: URL
    let remote: URL
    let server: ServerProfile
    let otherServer: ServerProfile
    let preferences: JSONWorkspacePreferenceStore
    let queue: JSONTransferQueueStore
    let servers: JSONSavedServerStore
    let client: TestRemoteClient

    init(delay: TimeInterval = 0) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        local = root.appendingPathComponent("Local", isDirectory: true)
        remote = root.appendingPathComponent("Remote", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        server = ServerProfile(name: "Restore", endpoint: "restore.example.com", port: 22, username: "user",
            connectionKind: .sftp, defaultLocalDirectoryPath: local.path, defaultRemotePath: remote.path,
            systemImage: "server.rack", accentName: "Orange")
        otherServer = ServerProfile(name: "Other", endpoint: "other.example.com", port: 22, username: "user",
            connectionKind: .sftp, defaultLocalDirectoryPath: local.path, defaultRemotePath: remote.path,
            systemImage: "server.rack", accentName: "Orange")
        preferences = JSONWorkspacePreferenceStore(fileURL: root.appendingPathComponent("Preferences.json"))
        queue = JSONTransferQueueStore(fileURL: root.appendingPathComponent("Queue.json"))
        servers = JSONSavedServerStore(fileURL: root.appendingPathComponent("Servers.json"))
        try servers.saveServers([server, otherServer])
        client = TestRemoteClient(remoteRootURL: remote, uploadChunkDelay: delay, downloadChunkDelay: delay)
    }

    func makeState(queue overrideQueue: (any TransferQueueStore)? = nil) -> FilePierWorkspaceState {
        let client = self.client
        return FilePierWorkspaceState(localFileBrowser: LocalFileBrowserService(), remoteClient: client,
            remoteClientFactory: { _, _, _ in RemoteSessionServices(client: client) },
            savedServerStore: servers, workspacePreferenceStore: preferences, transferQueueStore: overrideQueue ?? queue,
            siteUsageStore: JSONSiteUsageStore(fileURL: root.appendingPathComponent("Usage.json")),
            credentialStore: InMemoryServerCredentialStore(), initialLocalDirectoryURL: local, initialRemoteDirectoryURL: remote)
    }

    func savedTransfer(source: URL, upload: Bool) throws -> SavedTransfer {
        let descriptor: TransferRetryDescriptor
        if upload {
            descriptor = .uploadFile(sourceURL: source, destination: client.makeLocation(for: remote))
        } else {
            let item = try #require(LocalFileBrowserService().loadItems(in: source.deletingLastPathComponent()).first { $0.url?.path == source.path })
            descriptor = .downloadFile(item: item, destinationDirectoryURL: local)
        }
        return SavedTransfer(id: UUID(), title: source.lastPathComponent, server: TransferServerIdentity(server),
            localAccess: SavedLocalDirectory(url: upload ? source : local), descriptor: descriptor,
            conflictPolicy: .rename, isDirectory: source.hasDirectoryPath)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}
