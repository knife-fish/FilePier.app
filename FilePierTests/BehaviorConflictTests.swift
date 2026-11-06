import Foundation
import Testing
@testable import FilePier

nonisolated private final class ConflictTransferTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    var current: Int { lock.withLock { active } }
    var maximum: Int { lock.withLock { peak } }
    func enter() { lock.withLock { active += 1; peak = max(peak, active) } }
    func leave() { lock.withLock { active -= 1 } }
}

nonisolated private final class ConflictOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func wait() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

nonisolated private final class ConflictRemoteClient: RemoteClient, @unchecked Sendable {
    let root: URL
    let logical: Bool
    let readDelay: TimeInterval
    let childDelay: TimeInterval
    let uploadDelay: TimeInterval
    private let lock = NSLock()
    private let tracker: ConflictTransferTracker
    private var reads: [String: Int] = [:]
    private var deletes: [String] = []
    private let uploadGate: ConflictOperationGate?
    private let childReadGate: ConflictOperationGate?
    func releaseUploads() { uploadGate?.release() }
    func releaseChildReads() { childReadGate?.release() }
    var requiresUploadStaging: Bool { false }
    init(root: URL, logical: Bool = false, readDelay: TimeInterval = 0,
         childDelay: TimeInterval = 0, uploadDelay: TimeInterval = 0,
         tracker: ConflictTransferTracker = ConflictTransferTracker(), holdUploads: Bool = false,
         holdChildReads: Bool = false) {
        self.root = root; self.logical = logical; self.readDelay = readDelay
        self.childDelay = childDelay; self.uploadDelay = uploadDelay; self.tracker = tracker
        uploadGate = holdUploads ? ConflictOperationGate() : nil
        childReadGate = holdChildReads ? ConflictOperationGate() : nil
    }
    var maxActive: Int { tracker.maximum }
    var activeCount: Int { tracker.current }
    func readCount(_ path: String) -> Int { lock.withLock { reads[path, default: 0] } }
    var deletePaths: [String] { lock.withLock { deletes } }
    func physical(_ path: String) -> URL { logical ? root.appendingPathComponent(String(path.dropFirst())) : URL(fileURLWithPath: path) }
    func makeInitialLocation(relativeTo local: URL) -> RemoteLocation {
        logical ? makeLocation(for: URL(fileURLWithPath: "/")) : MockRemoteClient().makeLocation(for: root)
    }
    func makeLocation(for url: URL) -> RemoteLocation {
        logical ? RemoteLocation(id: url.path, path: "review://host\(url.path)", remotePath: url.path, directoryURL: nil)
            : MockRemoteClient().makeLocation(for: url)
    }
    func parentLocation(of location: RemoteLocation) -> RemoteLocation? {
        guard location.remotePath != "/" else { return nil }
        return makeLocation(for: URL(fileURLWithPath: location.remotePath).deletingLastPathComponent())
    }
    func location(for item: BrowserItem, from current: RemoteLocation) -> RemoteLocation? {
        item.isDirectory ? makeLocation(for: URL(fileURLWithPath: item.pathDescription)) : nil
    }
    func destinationDirectoryURL(for location: RemoteLocation) -> URL? { logical ? nil : physical(location.remotePath) }
    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        lock.withLock { reads[location.remotePath, default: 0] += 1 }
        if location.remotePath == "/common" { childReadGate?.wait() }
        Thread.sleep(forTimeInterval: location.remotePath == "/common" ? childDelay : readDelay)
        let items = try LocalFileBrowserService().loadItems(in: physical(location.remotePath))
        let mapped = logical ? items.map { item in
            let path = (location.remotePath as NSString).appendingPathComponent(item.name)
            return BrowserItem(id: path, name: item.name, kind: item.kind, byteCount: item.byteCount,
                modifiedAt: item.modifiedAt, sizeDescription: item.sizeDescription,
                modifiedDescription: item.modifiedDescription, pathDescription: path, url: nil)
        } : items
        return RemoteDirectorySnapshot(location: location, items: mapped, homePath: logical ? "/" : root.path)
    }
    func uploadItem(at localURL: URL, to location: RemoteLocation, conflictPolicy: TransferConflictPolicy,
                    progress: (@Sendable (TransferProgressSnapshot) -> Void)?, isCancelled: (@Sendable () -> Bool)?) throws -> RemoteUploadResult {
        tracker.enter()
        defer { tracker.leave() }
        uploadGate?.wait()
        Thread.sleep(forTimeInterval: uploadDelay)
        return try MockRemoteClient().uploadItem(at: localURL,
            to: MockRemoteClient().makeLocation(for: physical(location.remotePath)),
            conflictPolicy: conflictPolicy, progress: progress, isCancelled: isCancelled)
    }
    func downloadItem(named name: String, at path: String, toDirectory local: URL,
                      localFileTransfer: LocalFileTransferService, conflictPolicy: TransferConflictPolicy,
                      progress: (@Sendable (TransferProgressSnapshot) -> Void)?, isCancelled: (@Sendable () -> Bool)?) throws -> LocalFileTransferResult {
        tracker.enter()
        defer { tracker.leave() }
        Thread.sleep(forTimeInterval: uploadDelay)
        return try MockRemoteClient().downloadItem(named: name, at: physical(path).path, toDirectory: local,
            localFileTransfer: localFileTransfer, conflictPolicy: conflictPolicy, progress: progress, isCancelled: isCancelled)
    }
    func createDirectory(named name: String, in location: RemoteLocation) throws -> RemoteMutationResult {
        try MockRemoteClient().createDirectory(named: name, in: MockRemoteClient().makeLocation(for: physical(location.remotePath)))
    }
    func renameItem(named name: String, at path: String, to proposed: String) throws -> RemoteMutationResult {
        try MockRemoteClient().renameItem(named: name, at: physical(path).path, to: proposed)
    }
    func deleteItem(named name: String, at path: String, isDirectory: Bool, recursively: Bool) throws {
        lock.withLock { deletes.append(path) }
        try MockRemoteClient().deleteItem(named: name, at: physical(path).path, isDirectory: isDirectory, recursively: recursively)
    }
}

@MainActor
private struct ConflictFixture {
    let root: URL
    let local: URL
    let remoteA: URL
    let remoteB: URL
    let serverA: ServerProfile
    let serverB: ServerProfile
    let servers: JSONSavedServerStore
    let queue: JSONTransferQueueStore
    let sources: [URL]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        local = root.appendingPathComponent("Local", isDirectory: true)
        remoteA = root.appendingPathComponent("A", isDirectory: true)
        remoteB = root.appendingPathComponent("B", isDirectory: true)
        for folder in [local, remoteA, remoteB] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let localRoot = local
        sources = try ["one.txt", "two.txt", "three.txt"].map { name in
            let url = localRoot.appendingPathComponent(name)
            try "content".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        serverA = ServerProfile(name: "A", endpoint: "a.example.com", port: 22, username: "test",
            connectionKind: .sftp, systemImage: "server.rack", accentName: "Orange")
        serverB = ServerProfile(name: "B", endpoint: "b.example.com", port: 22, username: "test",
            connectionKind: .sftp, systemImage: "server.rack", accentName: "Orange")
        servers = JSONSavedServerStore(fileURL: root.appendingPathComponent("Servers.json"))
        queue = JSONTransferQueueStore(fileURL: root.appendingPathComponent("Queue.json"))
        try servers.saveServers([serverA, serverB])
    }

    func state(_ a: ConflictRemoteClient, _ b: ConflictRemoteClient? = nil,
               coordinator: TransferCoordinator? = nil) -> FilePierWorkspaceState {
        FilePierWorkspaceState(localFileBrowser: LocalFileBrowserService(), remoteClient: a,
            remoteClientFactory: { server, _, _ in RemoteSessionServices(client: server.id == serverB.id ? (b ?? a) : a) },
            savedServerStore: servers, favoritePlaceStore: JSONFavoritePlaceStore(fileURL: root.appendingPathComponent("Favorites.json")),
            workspacePreferenceStore: InMemoryWorkspacePreferenceStore(), transferQueueStore: queue,
            transferCoordinator: coordinator, siteUsageStore: JSONSiteUsageStore(fileURL: root.appendingPathComponent("Usage.json")),
            credentialStore: InMemoryServerCredentialStore(), initialLocalDirectoryURL: local)
    }
    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct BehaviorConflictTests {
    private struct Timeout: Error {}
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func disconnectedTransferEntrypointsAreRejected() async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        let client = ConflictRemoteClient(root: fixture.remoteA)
        let state = fixture.state(client)
        state.selectLocalItems(ids: Set(fixture.sources.prefix(2).map(\.path)))
        #expect(!state.canCopyFocusedSelectionToOtherPane)
        state.copyFocusedSelectionToOtherPane()
        #expect(!state.handleDrop(of: [fixture.sources[0]], into: .remote))
        #expect(!state.handleRemoteDrop(of: [.init(id: "/file", name: "file", pathDescription: "/file", isDirectory: false)], into: .local))
        #expect(state.recentTransfers.isEmpty)
        #expect(try fixture.queue.loadTransfers().isEmpty)
        #expect(client.maxActive == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.remoteA.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func oldDirectoryCheckCannotDeleteReplacementServer(nonEmpty: Bool) async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        for remote in [fixture.remoteA, fixture.remoteB] {
            try FileManager.default.createDirectory(at: remote.appendingPathComponent("common"), withIntermediateDirectories: true)
        }
        if nonEmpty {
            try "keep".write(to: fixture.remoteA.appendingPathComponent("common/keep.txt"), atomically: true, encoding: .utf8)
        }
        let a = ConflictRemoteClient(root: fixture.remoteA, logical: true, holdChildReads: true)
        defer { a.releaseChildReads() }
        let b = ConflictRemoteClient(root: fixture.remoteB, logical: true)
        let state = fixture.state(a, b)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        state.requestDelete(itemID: "/common", in: .remote)
        state.confirmDeleteRequest()
        try await waitUntil { a.readCount("/common") > 0 }
        state.selectServer(fixture.serverB)
        state.connectRemoteSession()
        a.releaseChildReads()
        try await waitUntil { state.isRemoteConnected && state.remoteSessionServerID == fixture.serverB.id }
        try await Task.sleep(for: .milliseconds(350))
        #expect(a.deletePaths.isEmpty && b.deletePaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.remoteA.appendingPathComponent("common").path))
        #expect(FileManager.default.fileExists(atPath: fixture.remoteB.appendingPathComponent("common").path))
        #expect(state.nonEmptyFolderDeleteRequest == nil)
        #expect(state.remoteActivityCount == 0)
    }

    @Test func oldTransferCannotInvalidateNewConnection() async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        let a = ConflictRemoteClient(root: fixture.remoteA, holdUploads: true)
        defer { a.releaseUploads() }
        let b = ConflictRemoteClient(root: fixture.remoteB, readDelay: 0.4)
        let state = fixture.state(a, b)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        #expect(state.handleDrop(of: [fixture.sources[0]], into: .remote))
        try await waitUntil { a.activeCount == 1 }
        state.selectServer(fixture.serverB)
        state.connectRemoteSession()
        a.releaseUploads()
        try await waitUntil { state.isRemoteConnected && state.remoteSessionServerID == fixture.serverB.id }
        #expect(b.readCount(fixture.remoteB.path(percentEncoded: false)) == 1)
        #expect(try fixture.queue.loadTransfers().isEmpty)
        #expect(state.remoteActivityCount == 0)
    }

    @Test func disconnectRejectsLateBrowserUpdates() async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        let client = ConflictRemoteClient(root: fixture.remoteA, holdUploads: true)
        defer { client.releaseUploads() }
        let state = fixture.state(client)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        #expect(state.handleDrop(of: [fixture.sources[0]], into: .remote))
        try await waitUntil { client.activeCount == 1 }
        state.disconnectRemoteSession()
        client.releaseUploads()
        try await waitUntil { state.recentTransfers.contains { $0.title == "one.txt" && $0.status == .completed } }
        #expect(state.remoteSessionStatus == .idle)
        #expect(state.remoteItems.isEmpty && state.selectedRemoteItemIDs.isEmpty)
        #expect(state.remoteActivityCount == 0)
        #expect(try fixture.queue.loadTransfers().isEmpty)
    }

    @Test func globalLimitIncludesSeparateBatchesAndBothDirections() async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        let download = fixture.remoteA.appendingPathComponent("download.log")
        try "download".write(to: download, atomically: true, encoding: .utf8)
        let client = ConflictRemoteClient(root: fixture.remoteA, uploadDelay: 0.1)
        let state = fixture.state(client)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        state.setMaxConcurrentTransfers(1)
        for source in fixture.sources { #expect(state.handleDrop(of: [source], into: .remote)) }
        #expect(state.handleRemoteDrop(of: [.init(id: download.path, name: download.lastPathComponent,
            pathDescription: download.path, isDirectory: false)], into: .local))
        try await waitUntil { state.recentTransfers.filter { $0.status == .completed }.count == 4 && !state.isRemoteBusy }
        #expect(client.maxActive == 1)
        #expect(try fixture.queue.loadTransfers().isEmpty)
        #expect(try String(contentsOf: fixture.local.appendingPathComponent("download.log"), encoding: .utf8) == "download")
    }

    @Test func windowsShareLiveQueueControlsAndConcurrencyWithoutRestoringAgain() async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        let coordinator = TransferCoordinator(store: fixture.queue)
        let client = ConflictRemoteClient(root: fixture.remoteA, holdUploads: true)
        defer { client.releaseUploads() }
        let first = fixture.state(client, coordinator: coordinator)
        first.connectRemoteSession()
        try await waitUntil { first.isRemoteConnected }
        first.setMaxConcurrentTransfers(1)
        #expect(first.handleDrop(of: [fixture.sources[0]], into: .remote))
        try await waitUntil { client.activeCount == 1 && first.recentTransfers.contains { $0.status == .running } }
        let second = fixture.state(client, coordinator: coordinator)
        #expect(second.recentTransfers == first.recentTransfers)
        #expect(!second.recentTransfers.contains { $0.status == .paused })
        let id = try #require(second.recentTransfers.first?.id)
        #expect(second.canCancelTransferActivity(id))
        second.setMaxConcurrentTransfers(2)
        #expect(first.maxConcurrentTransfers == 2)
        second.cancelTransferActivity(id)
        client.releaseUploads()
        try await waitUntil { !first.isRemoteBusy }
        #expect(first.recentTransfers.first?.status == .cancelled)
        #expect(second.recentTransfers.first?.status == .cancelled)
        #expect(try fixture.queue.loadTransfers().isEmpty)
        first.clearCompletedTransferActivities()
        second.clearCompletedTransferActivities()
        #expect(try fixture.queue.loadTransfers().isEmpty)
        let restarted = fixture.state(client)
        #expect(restarted.recentTransfers.isEmpty)
    }

    @Test func separateWindowsShareOneTransferLimit() async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        let coordinator = TransferCoordinator(store: fixture.queue, maxConcurrentTransfers: 1)
        let tracker = ConflictTransferTracker()
        let a = ConflictRemoteClient(root: fixture.remoteA, uploadDelay: 0.1, tracker: tracker)
        let b = ConflictRemoteClient(root: fixture.remoteB, uploadDelay: 0.1, tracker: tracker)
        let first = fixture.state(a, coordinator: coordinator)
        let second = fixture.state(b, coordinator: coordinator)
        first.connectRemoteSession()
        second.connectRemoteSession()
        try await waitUntil { first.isRemoteConnected && second.isRemoteConnected }
        first.setMaxConcurrentTransfers(1)
        #expect(first.handleDrop(of: [fixture.sources[0]], into: .remote))
        #expect(second.handleDrop(of: [fixture.sources[1]], into: .remote))
        try await waitUntil { coordinator.activities.filter { $0.status == .completed }.count == 2 && !first.isRemoteBusy && !second.isRemoteBusy }
        #expect(tracker.maximum == 1)
        #expect(try fixture.queue.loadTransfers().isEmpty)
    }

    @Test(arguments: [BrowserPane.local, .remote])
    func refreshAndTransferCompletionPreserveMultiSelection(pane: BrowserPane) async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        for name in ["alpha.log", "beta.log"] {
            try "remote".write(to: fixture.remoteA.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let client = ConflictRemoteClient(root: fixture.remoteA)
        let state = fixture.state(client)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        let ids: Set<String>
        if pane == .local {
            ids = Set(fixture.sources.prefix(2).map(\.path))
            state.selectLocalItems(ids: ids)
            state.refreshLocalDirectory()
            #expect(state.selectedLocalItemIDs == ids)
        } else {
            ids = Set(state.remoteItems.map(\.id))
            state.selectRemoteItems(ids: ids)
            state.refreshRemoteDirectory()
            try await waitUntil { !state.isRemoteBusy }
            #expect(state.selectedRemoteItemIDs == ids)
        }
        state.copyFocusedSelectionToOtherPane()
        try await waitUntil { state.recentTransfers.contains { $0.status == .completed } && !state.isRemoteBusy }
        #expect((pane == .local ? state.selectedLocalItemIDs : state.selectedRemoteItemIDs) == ids)
    }

    @Test func newDragPayloadDoesNotReusePreviousMultiSelection() async throws {
        let fixture = try ConflictFixture()
        defer { fixture.removeFiles() }
        let client = ConflictRemoteClient(root: fixture.remoteA)
        let state = fixture.state(client)
        state.connectRemoteSession()
        try await waitUntil { state.isRemoteConnected }
        state.selectLocalItems(ids: Set(fixture.sources.prefix(2).map(\.path)))
        let abandoned = try #require(LocalDragItemCodec.encode(Array(fixture.sources.prefix(2))))
        #expect(LocalDragItemCodec.decode(data: abandoned)?.count == 2)
        let current = try #require(LocalDragItemCodec.encode([fixture.sources[0]]))
        let dropped = try #require(LocalDragItemCodec.decode(data: current))
        #expect(state.handleDrop(of: dropped, into: .remote))
        try await waitUntil { state.recentTransfers.contains { $0.status == .completed } && !state.isRemoteBusy }
        #expect(FileManager.default.fileExists(atPath: fixture.remoteA.appendingPathComponent("one.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.remoteA.appendingPathComponent("two.txt").path))
    }
}
