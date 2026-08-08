import AppKit
import Foundation
import Combine
import Darwin
import Network

/// Expands `~/…` against the login account's home directory instead of the
/// App Sandbox container home directory.
func loginAccountHomeDirectoryPath() -> String? {
    guard let account = getpwuid(getuid()), let directory = account.pointee.pw_dir else {
        return nil
    }
    return String(cString: directory)
}

func expandingCurrentUserHomeDirectory(in path: String, homeDirectoryPath: String? = nil) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let resolvedHomeDirectory = homeDirectoryPath ?? loginAccountHomeDirectoryPath()
    guard let resolvedHomeDirectory else { return path }
    return resolvedHomeDirectory + String(path.dropFirst())
}

/// Returns the spelling that reaches a selected SSH key through `~/.ssh` when
/// that directory is a symbolic link. `NSOpenPanel` can return the link target
/// after navigating through the link, which would otherwise persist a path
/// outside the sandbox scope the user intended to grant.
func sshKeyPathPreservingHomeSSHLink(
    for selectedURL: URL,
    homeDirectoryURL: URL? = nil
) -> String {
    let selectedURL = selectedURL.standardizedFileURL
    let selectedPath = selectedURL.path(percentEncoded: false)
    let homeDirectoryURL = homeDirectoryURL ?? loginAccountHomeDirectoryPath().map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser
    let sshDirectoryURL = homeDirectoryURL
        .appendingPathComponent(".ssh", isDirectory: true)
        .standardizedFileURL

    guard
        let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: sshDirectoryURL.path(percentEncoded: false)
        )
    else {
        return selectedPath
    }

    let targetURL: URL
    if destination.hasPrefix("/") {
        targetURL = URL(fileURLWithPath: destination, isDirectory: true)
    } else {
        targetURL = sshDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(destination, isDirectory: true)
    }

    let resolvedTargetComponents = targetURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .pathComponents
    let resolvedSelectedComponents = selectedURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .pathComponents

    guard
        resolvedSelectedComponents.starts(with: resolvedTargetComponents),
        resolvedSelectedComponents.count > resolvedTargetComponents.count
    else {
        return selectedPath
    }

    return resolvedSelectedComponents
        .dropFirst(resolvedTargetComponents.count)
        .reduce(sshDirectoryURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        .path(percentEncoded: false)
}

struct ServerProfile: Identifiable, Hashable {
    let id: UUID
    let name: String
    let endpoint: String
    let port: Int
    let username: String
    let connectionKind: ConnectionKind
    let authenticationMode: ConnectionAuthenticationMode
    let privateKeyPath: String?
    let privateKeyBookmarkData: Data?
    let publicKeyPath: String?
    let publicKeyBookmarkData: Data?
    let addressPreference: ConnectionAddressPreference
    let s3Region: String?
    let defaultLocalDirectoryPath: String?
    let defaultRemotePath: String?
    let systemImage: String
    let accentName: String

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        port: Int,
        username: String,
        connectionKind: ConnectionKind,
        authenticationMode: ConnectionAuthenticationMode = .password,
        privateKeyPath: String? = nil,
        privateKeyBookmarkData: Data? = nil,
        publicKeyPath: String? = nil,
        publicKeyBookmarkData: Data? = nil,
        addressPreference: ConnectionAddressPreference = .automatic,
        s3Region: String? = nil,
        defaultLocalDirectoryPath: String? = nil,
        defaultRemotePath: String? = nil,
        systemImage: String,
        accentName: String
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.port = port
        self.username = username
        self.connectionKind = connectionKind
        self.authenticationMode = authenticationMode
        self.privateKeyPath = privateKeyPath
        self.privateKeyBookmarkData = privateKeyBookmarkData
        self.publicKeyPath = publicKeyPath
        self.publicKeyBookmarkData = publicKeyBookmarkData
        self.addressPreference = addressPreference
        self.s3Region = s3Region
        self.defaultLocalDirectoryPath = defaultLocalDirectoryPath
        self.defaultRemotePath = defaultRemotePath
        self.systemImage = systemImage
        self.accentName = accentName
    }
}

private extension Sequence where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

enum ConnectionAddressPreference: String, Hashable, CaseIterable, Codable {
    case automatic
    case ipv4
    case ipv6

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .ipv4: String(localized: "Prefer IPv4")
        case .ipv6: String(localized: "Prefer IPv6")
        }
    }
}

enum ConnectionKind: String, Hashable, CaseIterable, Codable {
    case sftp
    case webdav
    case cloud

    var title: String {
        switch self {
        case .sftp:
            return String(localized: "SFTP")
        case .webdav:
            return String(localized: "WebDAV")
        case .cloud:
            return String(localized: "S3-Compatible")
        }
    }
}

enum ConnectionAuthenticationMode: String, Hashable, CaseIterable, Codable {
    case password
    case sshKey

    var title: String {
        switch self {
        case .password:
            return String(localized: "Password")
        case .sshKey:
            return String(localized: "SSH Key")
        }
    }
}

enum BrowserDensityMode: String, CaseIterable, Codable {
    case comfortable
    case compact
    case ultraCompact

    var title: String {
        switch self {
        case .comfortable:
            return String(localized: "Comfortable")
        case .compact:
            return String(localized: "Compact")
        case .ultraCompact:
            return String(localized: "Ultra Compact")
        }
    }

    var systemImage: String {
        switch self {
        case .comfortable:
            return "rectangle.grid.1x2"
        case .compact:
            return "list.bullet"
        case .ultraCompact:
            return "list.dash"
        }
    }
}

enum BrowserSortField: String, CaseIterable, Codable {
    case name
    case modified
    case size

    var title: String {
        switch self {
        case .name:
            return String(localized: "Name")
        case .modified:
            return String(localized: "Modified")
        case .size:
            return String(localized: "Size")
        }
    }
}

struct BrowserSortOption: Codable, Equatable {
    var field: BrowserSortField
    var ascending: Bool

    static let `default` = BrowserSortOption(field: .name, ascending: true)

    var directionTitle: String {
        ascending ? String(localized: "Ascending") : String(localized: "Descending")
    }
}

enum SiteConnectionState: Equatable {
    case idle
    case connecting
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "Idle")
        case .connecting:
            return String(localized: "Connecting")
        case .connected:
            return String(localized: "Connected")
        case .failed:
            return String(localized: "Failed")
        }
    }
}

enum PlaceDestination: Hashable {
    case localDirectory(URL)
    case transfers
    case keys
}

struct PlaceItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let destination: PlaceDestination
    let isFavorite: Bool
    let allowsRemoval: Bool
}

struct FavoritePlaceRenameRequest: Identifiable, Equatable {
    let id = UUID()
    let placeID: String
    let originalName: String
    var proposedName: String
}

enum FileKind: String, CaseIterable {
    case folder
    case image
    case archive
    case document
    case code
}

struct BrowserItem: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: FileKind
    let byteCount: Int64?
    let modifiedAt: Date?
    let sizeDescription: String
    let modifiedDescription: String
    let pathDescription: String
    let url: URL?

    var isDirectory: Bool {
        kind == .folder
    }

    var iconName: String {
        switch kind {
        case .folder: "folder.fill"
        case .image: "photo"
        case .archive: "shippingbox.fill"
        case .document: "doc.text.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum TransferStatus: String, CaseIterable {
    case running
    case queued
    case paused
    case completed
    case cancelled
    case failed

    var label: String {
        rawValue.capitalized
    }

    var systemImage: String {
        switch self {
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .queued: "clock"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum TransferConflictPolicy: String {
    case rename
    case overwrite
}

struct TransferConflictResolutionRequest: Identifiable, Equatable {
    let id = UUID()
    let operationTitle: String
    let destinationSummary: String
    let conflictingNames: [String]
}

struct TransferActivity: Identifiable, Hashable {
    let id: UUID
    let title: String
    let detail: String
    let progress: Double
    let status: TransferStatus

    init(id: UUID = UUID(), title: String, detail: String, progress: Double, status: TransferStatus) {
        self.id = id
        self.title = title
        self.detail = detail
        self.progress = progress
        self.status = status
    }
}

private enum TransferRetryDescriptor {
    case uploadFile(sourceURL: URL, destination: RemoteLocation)
    case downloadFile(item: BrowserItem, destinationDirectoryURL: URL)
    case uploadBatch(sourceURLs: [URL], destination: RemoteLocation)
    case downloadBatch(items: [BrowserItem], destinationDirectoryURL: URL)
}

private enum PendingTransferLaunch {
    case upload(sourceURLs: [URL], sourcePane: BrowserPane?, targetItemID: BrowserItem.ID?, destination: RemoteLocation)
    case download(items: [BrowserItem], targetItemID: BrowserItem.ID?, destinationDirectoryURL: URL)
}

private final class TransferCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class TransferPauseController: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false

    func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    func waitWhilePaused(isCancelled: @escaping () -> Bool) throws {
        condition.lock()
        defer { condition.unlock() }

        while paused {
            if isCancelled() {
                throw CancellationError()
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
    }
}

private struct TransferControl {
    var cancellationController: TransferCancellationController?
    var pauseController: TransferPauseController?
    var pausedActivityDetail: String?
    var pausedActivityStatus: TransferStatus?
    var retryDescriptor: TransferRetryDescriptor?
}

enum BrowserPane: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: String(localized: "Local")
        case .remote: String(localized: "Remote")
        }
    }
}

struct TransferFeedback: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let status: TransferStatus
}

struct RenameRequest: Identifiable, Equatable {
    let id = UUID()
    let pane: BrowserPane
    let itemID: BrowserItem.ID
    let originalName: String
    var proposedName: String
}

struct DeleteRequest: Identifiable, Equatable {
    let id = UUID()
    let pane: BrowserPane
    let itemID: BrowserItem.ID
    let itemName: String
}

struct NonEmptyFolderDeleteRequest: Identifiable, Equatable {
    let id = UUID()
    let pane: BrowserPane
    let itemID: BrowserItem.ID
    let itemName: String
}

struct DeleteServerRequest: Identifiable, Equatable {
    let id = UUID()
    let server: ServerProfile
}

struct CreateFolderRequest: Identifiable, Equatable {
    let id = UUID()
    let pane: BrowserPane
    var proposedName: String
}

enum RemoteSessionStatus: Equatable {
    case idle
    case connecting
    case connected(String)
    case failed(String)
}

struct ConnectionDraft: Equatable {
    var name: String
    var host: String
    var port: String
    var username: String
    var authenticationMode: ConnectionAuthenticationMode
    var privateKeyPath: String
    var privateKeyBookmarkData: Data? = nil
    var publicKeyPath: String
    var publicKeyBookmarkData: Data? = nil
    var password: String
    var clearsSavedPassword: Bool
    var connectionKind: ConnectionKind
    var addressPreference: ConnectionAddressPreference
    var s3Region: String
    var defaultLocalDirectoryPath: String
    var defaultRemotePath: String

    static func from(server: ServerProfile?) -> ConnectionDraft {
        ConnectionDraft(
            name: server?.name ?? "",
            host: server?.endpoint ?? "",
            port: server.map { String($0.port) } ?? "22",
            username: server?.username ?? "",
            authenticationMode: server?.authenticationMode ?? .password,
            privateKeyPath: server?.privateKeyPath ?? "",
            privateKeyBookmarkData: server?.privateKeyBookmarkData,
            publicKeyPath: server?.publicKeyPath ?? "",
            publicKeyBookmarkData: server?.publicKeyBookmarkData,
            password: "",
            clearsSavedPassword: false,
            connectionKind: server?.connectionKind ?? .sftp,
            addressPreference: server?.addressPreference ?? .automatic,
            s3Region: server?.s3Region ?? "us-east-1",
            defaultLocalDirectoryPath: server?.defaultLocalDirectoryPath ?? "",
            defaultRemotePath: server?.defaultRemotePath ?? ""
        )
    }
}

struct RemoteDragItem: Hashable {
    let id: String
    let name: String
    let pathDescription: String
    let isDirectory: Bool
}

protocol NetworkReachabilityMonitoring: AnyObject {
    func setUpdateHandler(_ handler: @escaping @Sendable (Bool) -> Void)
    func start()
    func cancel()
}

final class LiveNetworkReachabilityMonitor: NetworkReachabilityMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: AppConfiguration.queueLabel("network-reachability"), qos: .utility)
    private var handler: (@Sendable (Bool) -> Void)?

    func setUpdateHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func start() {
        monitor.pathUpdateHandler = { [handler] path in
            handler?(Self.isReachable(path))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private static func isReachable(_ path: NWPath) -> Bool {
        guard path.status == .satisfied else { return false }

        // `satisfied` can still be true when only loopback or transient virtual routes remain.
        // Require at least one interface type that can carry a real remote session.
        return path.usesInterfaceType(.wifi)
            || path.usesInterfaceType(.wiredEthernet)
            || path.usesInterfaceType(.cellular)
            || path.usesInterfaceType(.other)
    }
}

@MainActor
final class FilePierWorkspaceState: ObservableObject {
    typealias RemoteSessionFactory = (ServerProfile, ConnectionDraft, LocalFileBrowserService) -> RemoteSessionServices

    @Published var selectedServer: ServerProfile?
    @Published private(set) var remoteSessionServerID: UUID?
    @Published var focusedPane: BrowserPane = .local
    @Published var showsInspector = true
    @Published var browserDensity: BrowserDensityMode = .comfortable
    @Published var maxConcurrentTransfers = WorkspacePreferences.default.maxConcurrentTransfers
    @Published var localBrowserSort = WorkspacePreferences.default.localBrowserSort
    @Published var remoteBrowserSort = WorkspacePreferences.default.remoteBrowserSort
    @Published var localItems: [BrowserItem]
    @Published var remoteItems: [BrowserItem]
    @Published var places: [PlaceItem]
    @Published var recentTransfers: [TransferActivity]
    @Published var servers: [ServerProfile]
    @Published private(set) var siteUsageByServerID: [UUID: SiteUsageRecord]
    @Published var localDirectoryURL: URL
    @Published var remoteLocation: RemoteLocation
    @Published var selectedLocalItemID: BrowserItem.ID?
    @Published var selectedRemoteItemID: BrowserItem.ID?
    @Published var selectedLocalItemIDs: Set<BrowserItem.ID>
    @Published var selectedRemoteItemIDs: Set<BrowserItem.ID>
    @Published var localErrorMessage: String?
    @Published var remoteErrorMessage: String?
    @Published var transferFeedback: TransferFeedback?
    @Published var renameRequest: RenameRequest?
    @Published var deleteRequest: DeleteRequest?
    @Published var nonEmptyFolderDeleteRequest: NonEmptyFolderDeleteRequest?
    @Published var deleteServerRequest: DeleteServerRequest?
    @Published var createFolderRequest: CreateFolderRequest?
    @Published var favoriteRenameRequest: FavoritePlaceRenameRequest?
    @Published var transferConflictResolutionRequest: TransferConflictResolutionRequest?
    @Published var connectionDraft: ConnectionDraft
    @Published var hasSavedPasswordForSelectedServer: Bool
    @Published var remoteSessionStatus: RemoteSessionStatus = .idle
    @Published var showsConnectionSheet = false
    @Published var showsRemotePathSheet = false
    @Published var remotePathDraft = ""
    @Published private(set) var remoteHomePath: String?
    @Published private(set) var remoteActivityCount = 0
    @Published private(set) var isNetworkReachable = true

    private let localFileBrowser: LocalFileBrowserService
    private let savedServerStore: any SavedServerStore
    private let favoritePlaceStore: any FavoritePlaceStore
    private let workspacePreferenceStore: any WorkspacePreferenceStore
    private let siteUsageStore: any SiteUsageStore
    private let credentialStore: any ServerCredentialStore
    private let networkMonitor: (any NetworkReachabilityMonitoring)?
    private var remoteClient: any RemoteClient
    private let localFileTransfer: LocalFileTransferService
    private let remoteSessionFactory: RemoteSessionFactory
    private var remoteConnectionAttemptID = UUID()
    private let remoteWorkQueue = DispatchQueue(
        label: AppConfiguration.queueLabel("remote-work"),
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let transferExecutionQueue = DispatchQueue(
        label: AppConfiguration.queueLabel("transfer-execution"),
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var transferControls: [UUID: TransferControl] = [:]
    private var localSecurityScopeRootURL: URL?
    private var pendingTransferLaunch: PendingTransferLaunch?
    private var activeLocalDragURLs: [URL] = []

    @MainActor
    init() {
        let savedServerStore = JSONSavedServerStore()
        let favoritePlaceStore = JSONFavoritePlaceStore()
        let workspacePreferenceStore = JSONWorkspacePreferenceStore()
        let siteUsageStore = JSONSiteUsageStore()
        let credentialStore = KeychainServerCredentialStore()
        let networkMonitor = LiveNetworkReachabilityMonitor()
        let initialServers = Self.loadInitialServers(savedServerStore: savedServerStore)
        let initialPreferences = Self.loadInitialWorkspacePreferences(workspacePreferenceStore: workspacePreferenceStore)
        let initialSiteUsage = Self.loadInitialSiteUsage(siteUsageStore: siteUsageStore)
        let initialSelectedServer = initialServers.first
        let initialConnectionDraft = Self.makeConnectionDraft(
            for: initialSelectedServer,
            credentialStore: credentialStore
        )

        self.localFileBrowser = LocalFileBrowserService()
        self.savedServerStore = savedServerStore
        self.favoritePlaceStore = favoritePlaceStore
        self.workspacePreferenceStore = workspacePreferenceStore
        self.siteUsageStore = siteUsageStore
        self.credentialStore = credentialStore
        self.networkMonitor = networkMonitor
        self.remoteClient = MockRemoteClient(localFileBrowser: self.localFileBrowser)
        self.localFileTransfer = LocalFileTransferService()
        self.remoteSessionFactory = Self.defaultRemoteSessionFactory
        self.servers = initialServers
        self.recentTransfers = []
        self.selectedServer = initialSelectedServer
        self.siteUsageByServerID = initialSiteUsage
        self.showsInspector = initialPreferences.showsInspector
        self.browserDensity = initialPreferences.browserDensity
        self.maxConcurrentTransfers = initialPreferences.maxConcurrentTransfers
        self.localBrowserSort = initialPreferences.localBrowserSort
        self.remoteBrowserSort = initialPreferences.remoteBrowserSort
        self.connectionDraft = initialConnectionDraft
        self.hasSavedPasswordForSelectedServer = Self.hasSavedPassword(
            for: initialSelectedServer,
            credentialStore: credentialStore
        )

        let initialDirectory = localFileBrowser.makeInitialDirectoryURL()
        self.localDirectoryURL = initialDirectory
        self.remoteLocation = remoteClient.makeInitialLocation(relativeTo: initialDirectory)
        self.places = Self.initialPlaces(
            currentLocalDirectory: initialDirectory,
            favoritePlaceStore: favoritePlaceStore
        )
        self.localItems = []
        self.remoteItems = []
        self.selectedLocalItemIDs = []
        self.selectedRemoteItemIDs = []

        establishLocalDirectoryAccess(at: initialDirectory)
        configureNetworkMonitor()
        reloadDirectory(in: .local, selecting: nil)
        reloadDirectory(in: .remote, selecting: nil)
    }

    @MainActor
    init(
        localFileBrowser: LocalFileBrowserService,
        remoteClient: (any RemoteClient)? = nil,
        remoteClientFactory: RemoteSessionFactory? = nil,
        localFileTransfer: LocalFileTransferService = LocalFileTransferService(),
        savedServerStore: (any SavedServerStore)? = nil,
        favoritePlaceStore: (any FavoritePlaceStore)? = nil,
        workspacePreferenceStore: (any WorkspacePreferenceStore)? = nil,
        siteUsageStore: (any SiteUsageStore)? = nil,
        credentialStore: (any ServerCredentialStore)? = nil,
        networkMonitor: (any NetworkReachabilityMonitoring)? = nil,
        initialLocalDirectoryURL: URL,
        initialRemoteDirectoryURL: URL? = nil
    ) {
        let resolvedSavedServerStore = savedServerStore ?? JSONSavedServerStore()
        let resolvedFavoritePlaceStore = favoritePlaceStore ?? JSONFavoritePlaceStore()
        let resolvedWorkspacePreferenceStore = workspacePreferenceStore ?? JSONWorkspacePreferenceStore()
        let resolvedSiteUsageStore = siteUsageStore ?? JSONSiteUsageStore()
        let resolvedCredentialStore = credentialStore ?? KeychainServerCredentialStore()
        let initialServers = Self.loadInitialServers(savedServerStore: resolvedSavedServerStore)
        let initialPreferences = Self.loadInitialWorkspacePreferences(workspacePreferenceStore: resolvedWorkspacePreferenceStore)
        let initialSiteUsage = Self.loadInitialSiteUsage(siteUsageStore: resolvedSiteUsageStore)
        let initialSelectedServer = initialServers.first
        let initialConnectionDraft = Self.makeConnectionDraft(
            for: initialSelectedServer,
            credentialStore: resolvedCredentialStore
        )

        self.localFileBrowser = localFileBrowser
        self.savedServerStore = resolvedSavedServerStore
        self.favoritePlaceStore = resolvedFavoritePlaceStore
        self.workspacePreferenceStore = resolvedWorkspacePreferenceStore
        self.siteUsageStore = resolvedSiteUsageStore
        self.credentialStore = resolvedCredentialStore
        self.networkMonitor = networkMonitor
        self.remoteClient = remoteClient ?? MockRemoteClient(localFileBrowser: localFileBrowser)
        self.localFileTransfer = localFileTransfer
        self.remoteSessionFactory = remoteClientFactory ?? Self.defaultRemoteSessionFactory
        self.servers = initialServers
        self.recentTransfers = []
        self.selectedServer = initialSelectedServer
        self.siteUsageByServerID = initialSiteUsage
        self.showsInspector = initialPreferences.showsInspector
        self.browserDensity = initialPreferences.browserDensity
        self.maxConcurrentTransfers = initialPreferences.maxConcurrentTransfers
        self.localBrowserSort = initialPreferences.localBrowserSort
        self.remoteBrowserSort = initialPreferences.remoteBrowserSort
        self.connectionDraft = initialConnectionDraft
        self.hasSavedPasswordForSelectedServer = Self.hasSavedPassword(
            for: initialSelectedServer,
            credentialStore: resolvedCredentialStore
        )

        self.localDirectoryURL = initialLocalDirectoryURL
        self.remoteLocation = if let initialRemoteDirectoryURL {
            self.remoteClient.makeLocation(for: initialRemoteDirectoryURL)
        } else {
            self.remoteClient.makeInitialLocation(relativeTo: initialLocalDirectoryURL)
        }
        self.places = Self.initialPlaces(
            currentLocalDirectory: initialLocalDirectoryURL,
            favoritePlaceStore: resolvedFavoritePlaceStore
        )
        self.localItems = []
        self.remoteItems = []
        self.selectedLocalItemIDs = []
        self.selectedRemoteItemIDs = []

        establishLocalDirectoryAccess(at: initialLocalDirectoryURL)
        configureNetworkMonitor()
        reloadDirectory(in: .local, selecting: nil)
        reloadDirectory(in: .remote, selecting: nil)
    }

    var localPathDisplayName: String {
        localDirectoryURL.path(percentEncoded: false)
    }

    var remotePathDisplayName: String {
        remoteLocation.path
    }

    var canNavigateToLocalParent: Bool {
        let standardized = localDirectoryURL.standardizedFileURL
        return standardized.path != standardized.deletingLastPathComponent().path
    }

    var canNavigateToRemoteParent: Bool {
        remoteClient.parentLocation(of: remoteLocation) != nil
    }

    var canNavigateToFocusedParent: Bool {
        switch focusedPane {
        case .local:
            canNavigateToLocalParent
        case .remote:
            canNavigateToRemoteParent
        }
    }

    var selectedItem: BrowserItem? {
        switch focusedPane {
        case .local:
            return localItems.first(where: { $0.id == selectedLocalItemID })
        case .remote:
            return remoteItems.first(where: { $0.id == selectedRemoteItemID })
        }
    }

    var selectedItems: [BrowserItem] {
        switch focusedPane {
        case .local:
            let selectedIDs = selectedLocalItemIDs
            return localItems.filter { selectedIDs.contains($0.id) }
        case .remote:
            let selectedIDs = selectedRemoteItemIDs
            return remoteItems.filter { selectedIDs.contains($0.id) }
        }
    }

    var canCopyFocusedSelectionToOtherPane: Bool {
        switch focusedPane {
        case .local:
            selectedItems.contains(where: { $0.url != nil })
        case .remote:
            isRemoteConnected && !selectedItems.isEmpty
        }
    }

    var canRenameFocusedSelection: Bool {
        switch focusedPane {
        case .local:
            selectedItem?.url != nil
        case .remote:
            isRemoteConnected && selectedItem != nil
        }
    }

    var canDeleteFocusedSelection: Bool {
        switch focusedPane {
        case .local:
            selectedItem?.url != nil
        case .remote:
            isRemoteConnected && selectedItem != nil
        }
    }

    var canCreateFolderInFocusedPane: Bool {
        switch focusedPane {
        case .local:
            true
        case .remote:
            isRemoteConnected
        }
    }

    var isRemoteConnected: Bool {
        guard isNetworkReachable else { return false }
        if case .connected = remoteSessionStatus {
            return true
        }
        return false
    }

    var isRemoteBusy: Bool {
        remoteActivityCount > 0 || remoteSessionStatus == .connecting
    }

    var isRemoteConnectionBusy: Bool {
        remoteSessionStatus == .connecting
    }

    var activeRemoteServer: ServerProfile? {
        guard let remoteSessionServerID else { return nil }
        return servers.first(where: { $0.id == remoteSessionServerID })
    }

    func connectionState(for server: ServerProfile) -> SiteConnectionState {
        guard remoteSessionServerID == server.id else { return .idle }

        if !isNetworkReachable, remoteSessionStatus == .connecting || isConnectedStatus(remoteSessionStatus) {
            return .failed(String(localized: "Network Offline"))
        }

        switch remoteSessionStatus {
        case .idle:
            return .idle
        case .connecting:
            return .connecting
        case .connected(let details):
            return .connected(details)
        case .failed(let message):
            return .failed(message)
        }
    }

    func siteUsage(for server: ServerProfile) -> SiteUsageRecord? {
        siteUsageByServerID[server.id]
    }

    var favoritePlaces: [PlaceItem] {
        places.filter(\.isFavorite)
    }

    var builtInPlaces: [PlaceItem] {
        places.filter { !$0.isFavorite && $0.destination != .transfers && $0.destination != .keys }
    }

    var workspacePlaces: [PlaceItem] {
        places.filter { !$0.isFavorite && ($0.destination == .transfers || $0.destination == .keys) }
    }

    func refreshLocalDirectory() {
        reloadDirectory(in: .local, selecting: selectedLocalItemID)
    }

    func refreshRemoteDirectory() {
        reloadRemoteDirectoryAsync(selecting: selectedRemoteItemID)
    }

    func refreshFocusedDirectory() {
        switch focusedPane {
        case .local:
            refreshLocalDirectory()
        case .remote:
            refreshRemoteDirectory()
        }
    }

    func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Local Folder")
        panel.message = String(localized: "Select a local folder to browse in the left pane.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = localDirectoryURL

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        setLocalDirectory(selectedURL.standardizedFileURL, securityScopeRoot: selectedURL.standardizedFileURL)
        localErrorMessage = nil
        reloadDirectory(in: .local, selecting: nil)
    }

    func openPlace(_ place: PlaceItem) {
        switch place.destination {
        case .localDirectory(let url):
            focusedPane = .local
            guard openLocalDirectory(url.standardizedFileURL, title: place.title) else {
                return
            }
            transferFeedback = TransferFeedback(
                message: String(localized: "Opened \(place.title) in Local."),
                status: .completed
            )
        case .transfers:
            setShowsInspector(true)
            transferFeedback = TransferFeedback(
                message: String(localized: "Recent transfers are shown in the inspector."),
                status: .completed
            )
        case .keys:
            showsConnectionSheet = true
            transferFeedback = TransferFeedback(
                message: String(localized: "SSH and connection settings are managed from site configuration."),
                status: .completed
            )
        }
    }

    func addCurrentLocalDirectoryToFavorites() {
        let directoryURL = localDirectoryURL.standardizedFileURL
        let path = directoryURL.path(percentEncoded: false)
        guard !favoritePlaces.contains(where: {
            if case .localDirectory(let existingURL) = $0.destination {
                return existingURL.standardizedFileURL.path(percentEncoded: false) == path
            }
            return false
        }) else {
            transferFeedback = TransferFeedback(
                message: String(localized: "\(directoryURL.lastPathComponent) is already in Favorites."),
                status: .completed
            )
            return
        }

        let favorite = Self.makeFavoritePlace(from: FavoritePlaceRecord(url: directoryURL))

        do {
            try saveFavoritePlaces([favorite] + favoritePlaces)
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Add to Favorites failed: \(error.localizedDescription)"),
                status: .failed
            )
            return
        }

        places.insert(favorite, at: 0)
        transferFeedback = TransferFeedback(
            message: String(localized: "Added \(favorite.title) to Favorites."),
            status: .completed
        )
    }

    func beginRenamingFavorite(_ place: PlaceItem) {
        guard place.isFavorite else { return }
        favoriteRenameRequest = FavoritePlaceRenameRequest(
            placeID: place.id,
            originalName: place.title,
            proposedName: place.title
        )
    }

    func submitFavoriteRenameRequest() {
        guard let favoriteRenameRequest else { return }
        let trimmedName = favoriteRenameRequest.proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            transferFeedback = TransferFeedback(
                message: String(localized: "Favorite name cannot be empty."),
                status: .failed
            )
            return
        }

        guard let index = places.firstIndex(where: { $0.id == favoriteRenameRequest.placeID }) else {
            self.favoriteRenameRequest = nil
            return
        }

        let originalPlace = places[index]
        guard case .localDirectory(let url) = originalPlace.destination else {
            self.favoriteRenameRequest = nil
            return
        }

        let updatedPlace = Self.makeFavoritePlace(
            from: FavoritePlaceRecord(url: url, customTitle: trimmedName)
        )

        var updatedFavorites = favoritePlaces
        guard let favoriteIndex = updatedFavorites.firstIndex(where: { $0.id == originalPlace.id }) else {
            self.favoriteRenameRequest = nil
            return
        }
        updatedFavorites[favoriteIndex] = updatedPlace

        do {
            try saveFavoritePlaces(updatedFavorites)
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Rename Favorite failed: \(error.localizedDescription)"),
                status: .failed
            )
            return
        }

        places[index] = updatedPlace
        self.favoriteRenameRequest = nil
        transferFeedback = TransferFeedback(
            message: String(localized: "Renamed favorite to \(trimmedName)."),
            status: .completed
        )
    }

    func cancelFavoriteRenameRequest() {
        favoriteRenameRequest = nil
    }

    func moveFavorite(_ place: PlaceItem, by delta: Int) {
        let favorites = favoritePlaces
        guard let sourceIndex = favorites.firstIndex(of: place) else { return }
        let destinationIndex = sourceIndex + delta
        guard favorites.indices.contains(destinationIndex) else { return }
        moveFavorite(fromOffsets: IndexSet(integer: sourceIndex), toOffset: delta > 0 ? destinationIndex + 1 : destinationIndex)
    }

    func moveFavorite(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var updatedFavorites = favoritePlaces
        let movingItems = offsets.map { updatedFavorites[$0] }
        for offset in offsets.sorted(by: >) {
            updatedFavorites.remove(at: offset)
        }

        var adjustedDestination = destination
        for offset in offsets where offset < destination {
            adjustedDestination -= 1
        }
        updatedFavorites.insert(contentsOf: movingItems, at: max(0, min(adjustedDestination, updatedFavorites.count)))

        do {
            try saveFavoritePlaces(updatedFavorites)
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Reorder Favorites failed: \(error.localizedDescription)"),
                status: .failed
            )
            return
        }

        places = updatedFavorites + Self.defaultPlaces(currentLocalDirectory: localDirectoryURL)
    }

    func removeFavorite(_ place: PlaceItem) {
        guard place.allowsRemoval else { return }

        do {
            try saveFavoritePlaces(favoritePlaces.filter { $0.id != place.id })
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Remove Favorite failed: \(error.localizedDescription)"),
                status: .failed
            )
            return
        }

        places.removeAll { $0.id == place.id }
        transferFeedback = TransferFeedback(
            message: String(localized: "Removed \(place.title) from Favorites."),
            status: .completed
        )
    }

    func setShowsInspector(_ showsInspector: Bool) {
        self.showsInspector = showsInspector
        persistWorkspacePreferences()
    }

    func toggleInspectorVisibility() {
        setShowsInspector(!showsInspector)
    }

    func setBrowserDensity(_ density: BrowserDensityMode) {
        browserDensity = density
        persistWorkspacePreferences()
    }

    func setMaxConcurrentTransfers(_ value: Int) {
        maxConcurrentTransfers = min(max(value, 1), 6)
        persistWorkspacePreferences()
    }

    func setBrowserSort(_ sort: BrowserSortOption, for pane: BrowserPane) {
        switch pane {
        case .local:
            localBrowserSort = sort
            localItems = sortItems(localItems, using: sort)
        case .remote:
            remoteBrowserSort = sort
            remoteItems = sortItems(remoteItems, using: sort)
        }
        persistWorkspacePreferences()
    }

    func canRetryTransferActivity(_ id: UUID) -> Bool {
        guard let activity = recentTransfers.first(where: { $0.id == id }) else { return false }
        guard activity.status == .failed || activity.status == .cancelled else { return false }
        return transferControls[id]?.retryDescriptor != nil
    }

    func canCancelTransferActivity(_ id: UUID) -> Bool {
        guard let activity = recentTransfers.first(where: { $0.id == id }) else { return false }
        guard activity.status == .queued || activity.status == .running || activity.status == .paused else { return false }
        return transferControls[id]?.cancellationController != nil
    }

    func canPauseTransferActivity(_ id: UUID) -> Bool {
        guard let activity = recentTransfers.first(where: { $0.id == id }) else { return false }
        guard activity.status == .queued || activity.status == .running else { return false }
        guard let control = transferControls[id] else { return false }
        return control.pauseController != nil && control.pauseController?.isPaused == false
    }

    func canResumeTransferActivity(_ id: UUID) -> Bool {
        guard let activity = recentTransfers.first(where: { $0.id == id }) else { return false }
        guard activity.status == .paused else { return false }
        return transferControls[id]?.pauseController?.isPaused == true
    }

    var hasCompletedTransferActivities: Bool {
        recentTransfers.contains { $0.status == .completed }
    }

    func clearCompletedTransferActivities() {
        let completedIDs = Set(
            recentTransfers
                .filter { $0.status == .completed }
                .map(\.id)
        )
        guard !completedIDs.isEmpty else { return }

        recentTransfers.removeAll { completedIDs.contains($0.id) }
        transferControls = transferControls.filter { !completedIDs.contains($0.key) }
    }

    func pauseTransferActivity(_ id: UUID) {
        guard canPauseTransferActivity(id) else { return }
        guard let activity = recentTransfers.first(where: { $0.id == id }) else { return }
        guard var control = transferControls[id], let pauseController = control.pauseController else { return }

        pauseController.pause()
        control.pausedActivityDetail = activity.detail
        control.pausedActivityStatus = activity.status
        transferControls[id] = control

        let pausedDetail: String
        switch activity.status {
        case .queued:
            pausedDetail = String(localized: "Paused before transfer started.")
        case .running:
            pausedDetail = String(localized: "Paused. \(activity.detail)")
        default:
            pausedDetail = activity.detail
        }

        replaceTransferActivity(
            id: id,
            with: .init(
                id: id,
                title: activity.title,
                detail: pausedDetail,
                progress: activity.progress,
                status: .paused
            )
        )
    }

    func resumeTransferActivity(_ id: UUID) {
        guard canResumeTransferActivity(id) else { return }
        guard let activity = recentTransfers.first(where: { $0.id == id }) else { return }
        guard var control = transferControls[id], let pauseController = control.pauseController else { return }

        pauseController.resume()
        let resumedDetail = control.pausedActivityDetail ?? activity.detail
        let resumedStatus = control.pausedActivityStatus ?? (activity.progress > 0 ? .running : .queued)
        control.pausedActivityDetail = nil
        control.pausedActivityStatus = nil
        transferControls[id] = control

        replaceTransferActivity(
            id: id,
            with: .init(
                id: id,
                title: activity.title,
                detail: resumedDetail,
                progress: activity.progress,
                status: resumedStatus
            )
        )
    }

    func cancelTransferActivity(_ id: UUID) {
        guard let controller = transferControls[id]?.cancellationController else { return }
        controller.cancel()
        transferControls[id]?.pauseController?.resume()
        if let activity = recentTransfers.first(where: { $0.id == id }), activity.status == .queued || activity.status == .paused {
            replaceTransferActivity(
                id: id,
                with: .init(
                    id: id,
                    title: activity.title,
                    detail: activity.status == .paused
                        ? String(localized: "Cancelled while paused.")
                        : String(localized: "Cancelled before transfer started."),
                    progress: activity.progress,
                    status: .cancelled
                )
            )
            transferControls[id]?.cancellationController = nil
        }
    }

    func retryTransferActivity(_ id: UUID) {
        guard let descriptor = transferControls[id]?.retryDescriptor else { return }

        switch descriptor {
        case .uploadFile(let sourceURL, let destination):
            retryUploadTransfer(sourceURL: sourceURL, destination: destination)
        case .downloadFile(let item, let destinationDirectoryURL):
            retryDownloadTransfer(item: item, destinationDirectoryURL: destinationDirectoryURL)
        case .uploadBatch(let sourceURLs, let destination):
            let existingURLs = sourceURLs.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            guard !existingURLs.isEmpty else {
                transferFeedback = TransferFeedback(
                    message: String(localized: "Retry failed: none of the failed upload sources still exist."),
                    status: .failed
                )
                return
            }
            uploadLocalItems(existingURLs, from: nil, destinationOverride: destination)
        case .downloadBatch(let items, let destinationDirectoryURL):
            guard FileManager.default.fileExists(atPath: destinationDirectoryURL.path(percentEncoded: false)) else {
                transferFeedback = TransferFeedback(
                    message: String(localized: "Retry failed: destination folder no longer exists."),
                    status: .failed
                )
                return
            }
            guard !items.isEmpty else { return }
            downloadRemoteItems(items, to: .local, destinationDirectoryOverride: destinationDirectoryURL)
        }
    }

    func navigateToLocalParent() {
        guard canNavigateToLocalParent else { return }
        setLocalDirectory(localDirectoryURL.deletingLastPathComponent())
        reloadDirectory(in: .local, selecting: nil)
    }

    func navigateToRemoteParent() {
        guard let parentLocation = remoteClient.parentLocation(of: remoteLocation) else { return }
        remoteLocation = parentLocation
        reloadRemoteDirectoryAsync(selecting: nil)
    }

    func navigateFocusedPaneToParent() {
        switch focusedPane {
        case .local:
            navigateToLocalParent()
        case .remote:
            navigateToRemoteParent()
        }
    }

    func openLocalSelection() {
        guard
            let selectedLocalItemID,
            let item = localItems.first(where: { $0.id == selectedLocalItemID }),
            let url = item.url,
            item.isDirectory
        else {
            return
        }

        setLocalDirectory(url)
        reloadDirectory(in: .local, selecting: nil)
    }

    func openRemoteSelection() {
        guard
            let selectedRemoteItemID,
            let item = remoteItems.first(where: { $0.id == selectedRemoteItemID }),
            let nextLocation = remoteClient.location(for: item, from: remoteLocation)
        else {
            return
        }

        remoteLocation = nextLocation
        reloadRemoteDirectoryAsync(selecting: nil)
    }

    func openFocusedSelection() {
        switch focusedPane {
        case .local:
            openLocalSelection()
        case .remote:
            openRemoteSelection()
        }
    }

    func copyFocusedSelectionToOtherPane() {
        let sourcePane = focusedPane
        let destinationPane: BrowserPane = sourcePane == .local ? .remote : .local

        switch sourcePane {
        case .local:
            let sourceURLs = selectedItems.compactMap(\.url)
            guard !sourceURLs.isEmpty else { return }
            copyItems(at: sourceURLs, from: sourcePane, to: destinationPane)
        case .remote:
            let items = selectedItems
            guard !items.isEmpty else { return }
            downloadRemoteItems(items, to: destinationPane)
        }
    }

    func handleDrop(of sourceURLs: [URL], into destinationPane: BrowserPane, targetItemID: BrowserItem.ID? = nil) -> Bool {
        let destinationDirectoryURL = directoryURL(for: destinationPane, targetItemID: targetItemID)
        let sanitizedURLs = sourceURLs.map(\.standardizedFileURL).filter { url in
            url.path(percentEncoded: false) != destinationDirectoryURL.path(percentEncoded: false)
        }
        guard !sanitizedURLs.isEmpty else { return false }

        if destinationPane == .remote {
            guard isRemoteConnected else {
                transferFeedback = TransferFeedback(
                    message: String(localized: "Connect a site before uploading with drag and drop."),
                    status: .failed
                )
                return false
            }
        }

        copyItems(at: sanitizedURLs, from: nil, to: destinationPane, targetItemID: targetItemID)
        focusedPane = destinationPane
        return true
    }

    func handleRemoteDrop(of items: [RemoteDragItem], into destinationPane: BrowserPane, targetItemID: BrowserItem.ID? = nil) -> Bool {
        guard destinationPane == .local else { return false }

        downloadRemoteItems(
            items.map {
                BrowserItem(
                    id: $0.id,
                    name: $0.name,
                    kind: $0.isDirectory ? .folder : .document,
                    byteCount: nil,
                    modifiedAt: nil,
                    sizeDescription: $0.isDirectory ? "--" : "--",
                    modifiedDescription: "",
                    pathDescription: $0.pathDescription,
                    url: nil
                )
            },
            to: destinationPane,
            targetItemID: targetItemID
        )
        focusedPane = destinationPane
        return true
    }

    func dismissTransferFeedback() {
        transferFeedback = nil
    }

    func selectServer(_ server: ServerProfile) {
        if remoteSessionServerID != server.id && !isConnectedStatus(remoteSessionStatus) {
            resetRemoteSession(showFeedback: false, displayHost: server.endpoint)
            transferFeedback = nil
        }
        selectedServer = server
        connectionDraft = Self.makeConnectionDraft(for: server, credentialStore: credentialStore)
        hasSavedPasswordForSelectedServer = Self.hasSavedPassword(for: server, credentialStore: credentialStore)
    }

    func presentConnectionSheet() {
        showsConnectionSheet = true
    }

    func beginCreatingSite() {
        selectedServer = nil
        connectionDraft = ConnectionDraft.from(server: nil)
        hasSavedPasswordForSelectedServer = false
        showsConnectionSheet = true
    }

    func editSelectedSite() {
        presentConnectionSheet()
    }

    func duplicateServer(_ server: ServerProfile) {
        let duplicate = ServerProfile(
            id: UUID(),
            name: uniqueDuplicateServerName(for: server.name),
            endpoint: server.endpoint,
            port: server.port,
            username: server.username,
            connectionKind: server.connectionKind,
            authenticationMode: server.authenticationMode,
            privateKeyPath: server.privateKeyPath,
            publicKeyPath: server.publicKeyPath,
            addressPreference: server.addressPreference,
            s3Region: server.s3Region,
            defaultLocalDirectoryPath: server.defaultLocalDirectoryPath,
            defaultRemotePath: server.defaultRemotePath,
            systemImage: server.systemImage,
            accentName: server.accentName
        )

        var updatedServers = servers
        let insertionIndex = (updatedServers.firstIndex(where: { $0.id == server.id }) ?? -1) + 1
        updatedServers.insert(duplicate, at: min(insertionIndex, updatedServers.count))

        do {
            try savedServerStore.saveServers(updatedServers)
            if let password = try? credentialStore.password(for: server.id), password.isEmpty == false {
                try credentialStore.setPassword(password, for: duplicate.id)
            }
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Copy site failed: \(error.localizedDescription)"),
                status: .failed
            )
            return
        }

        servers = updatedServers
        selectedServer = duplicate
        connectionDraft = Self.makeConnectionDraft(for: duplicate, credentialStore: credentialStore)
        hasSavedPasswordForSelectedServer = Self.hasSavedPassword(for: duplicate, credentialStore: credentialStore)
        transferFeedback = TransferFeedback(
            message: String(localized: "Copied site \(duplicate.name)."),
            status: .completed
        )
    }

    func requestDeleteServer(_ server: ServerProfile) {
        deleteServerRequest = DeleteServerRequest(server: server)
    }

    func confirmDeleteServerRequest() {
        guard let deleteServerRequest else { return }
        deleteServer(deleteServerRequest.server)
        self.deleteServerRequest = nil
    }

    func cancelDeleteServerRequest() {
        deleteServerRequest = nil
    }

    func clearSavedPasswordFromDraft() {
        connectionDraft.password = ""
        connectionDraft.clearsSavedPassword = true
        hasSavedPasswordForSelectedServer = false
    }

    func deleteServer(_ server: ServerProfile) {
        var updatedServers = servers
        updatedServers.removeAll { $0.id == server.id }
        var updatedUsage = siteUsageByServerID
        updatedUsage.removeValue(forKey: server.id)

        do {
            try savedServerStore.saveServers(updatedServers)
            try siteUsageStore.saveUsage(updatedUsage)
            try credentialStore.removePassword(for: server.id)
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Delete site failed: \(error.localizedDescription)"),
                status: .failed
            )
            return
        }

        servers = updatedServers
        siteUsageByServerID = updatedUsage
        if selectedServer?.id == server.id {
            selectedServer = servers.first
            connectionDraft = Self.makeConnectionDraft(for: selectedServer, credentialStore: credentialStore)
            hasSavedPasswordForSelectedServer = Self.hasSavedPassword(for: selectedServer, credentialStore: credentialStore)
        }
        if remoteSessionServerID == server.id {
            resetRemoteSession(showFeedback: false, displayHost: selectedServer?.endpoint)
        }

        transferFeedback = TransferFeedback(
            message: String(localized: "Deleted site \(server.name)."),
            status: .completed
        )
    }

    @discardableResult
    func saveConnectionDraftAsSite() -> ServerProfile? {
        let trimmedHost = connectionDraft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = connectionDraft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrivateKeyPath = connectionDraft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedHost.isEmpty,
            !trimmedUsername.isEmpty,
            connectionDraft.authenticationMode != .sshKey || !trimmedPrivateKeyPath.isEmpty
        else {
            return nil
        }

        let trimmedName = connectionDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(connectionDraft.port) ?? defaultPort(for: connectionDraft.connectionKind)
        let savedServer = ServerProfile(
            id: selectedServer?.id ?? UUID(),
            name: trimmedName.isEmpty ? trimmedHost : trimmedName,
            endpoint: trimmedHost,
            port: port,
            username: trimmedUsername,
            connectionKind: connectionDraft.connectionKind,
            authenticationMode: connectionDraft.authenticationMode,
            privateKeyPath: normalizedKeyDraftPath(connectionDraft.privateKeyPath),
            privateKeyBookmarkData: connectionDraft.privateKeyBookmarkData,
            publicKeyPath: normalizedKeyDraftPath(connectionDraft.publicKeyPath),
            publicKeyBookmarkData: connectionDraft.publicKeyBookmarkData,
            addressPreference: connectionDraft.addressPreference,
            s3Region: normalizedS3RegionDraft(connectionDraft.s3Region),
            defaultLocalDirectoryPath: normalizedLocalDirectoryDraftPath(connectionDraft.defaultLocalDirectoryPath),
            defaultRemotePath: normalizedRemoteDirectoryDraftPath(connectionDraft.defaultRemotePath),
            systemImage: systemImage(for: connectionDraft.connectionKind),
            accentName: accentName(for: connectionDraft.connectionKind)
        )

        var updatedServers = servers
        if let existingIndex = updatedServers.firstIndex(where: { $0.id == savedServer.id }) {
            updatedServers[existingIndex] = savedServer
        } else {
            updatedServers.insert(savedServer, at: 0)
        }

        do {
            try savedServerStore.saveServers(updatedServers)
            if connectionDraft.clearsSavedPassword {
                try credentialStore.removePassword(for: savedServer.id)
            } else if connectionDraft.password.isEmpty {
                if selectedServer == nil {
                    try credentialStore.removePassword(for: savedServer.id)
                }
            } else {
                try credentialStore.setPassword(connectionDraft.password, for: savedServer.id)
            }
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Save site failed: \(error.localizedDescription)"),
                status: .failed
            )
            return nil
        }

        servers = updatedServers
        selectedServer = savedServer
        connectionDraft = Self.makeConnectionDraft(for: savedServer, credentialStore: credentialStore)
        hasSavedPasswordForSelectedServer = !connectionDraft.password.isEmpty
        transferFeedback = TransferFeedback(
            message: String(localized: "Saved site \(savedServer.name)."),
            status: .completed
        )
        return savedServer
    }

    func disconnectRemoteSession() {
        resetRemoteSession(showFeedback: true, displayHost: activeRemoteServer?.endpoint ?? selectedServer?.endpoint)
    }

    func beginCreatingFolderInFocusedPane() {
        guard canCreateFolderInFocusedPane else { return }
        createFolderRequest = CreateFolderRequest(pane: focusedPane, proposedName: String(localized: "New Folder"))
    }

    func connectRemoteSession() {
        guard isNetworkReachable else {
            remoteSessionStatus = .failed(String(localized: "Network Offline"))
            remoteErrorMessage = String(localized: "Connect to a network before opening a remote session.")
            transferFeedback = TransferFeedback(
                message: String(localized: "Connect to a network before opening a remote session."),
                status: .failed
            )
            return
        }

        let resolvedServer = makeResolvedServer()
        remoteSessionServerID = resolvedServer.id
        remoteSessionStatus = .connecting
        let resolvedHost = connectionDraft.host.isEmpty ? resolvedServer.endpoint : connectionDraft.host
        let resolvedPort = Int(connectionDraft.port) ?? resolvedServer.port
        let resolvedUsername = connectionDraft.username.isEmpty ? resolvedServer.username : connectionDraft.username

        var resolvedDraft = connectionDraft
        resolvedDraft.name = resolvedServer.name
        resolvedDraft.host = resolvedHost
        resolvedDraft.port = String(resolvedPort)
        resolvedDraft.username = resolvedUsername
        resolvedDraft.password = resolvedPassword(for: resolvedServer)
        resolvedDraft.connectionKind = resolvedServer.connectionKind
        resolvedDraft.authenticationMode = resolvedServer.authenticationMode
        resolvedDraft.privateKeyPath = resolvedServer.privateKeyPath ?? ""
        resolvedDraft.publicKeyPath = resolvedServer.publicKeyPath ?? ""
        resolvedDraft.addressPreference = resolvedServer.addressPreference
        resolvedDraft.defaultLocalDirectoryPath = resolvedServer.defaultLocalDirectoryPath ?? ""
        resolvedDraft.defaultRemotePath = resolvedServer.defaultRemotePath ?? ""

        let services = remoteSessionFactory(resolvedServer, resolvedDraft, localFileBrowser)
        remoteClient = services.client
        let nextLocation = initialRemoteLocation(for: resolvedServer, client: services.client)
        remoteLocation = nextLocation
        remoteHomePath = nil
        remotePathDraft = nextLocation.remotePath
        remoteErrorMessage = nil
        remoteItems = []
        selectedRemoteItemID = nil

        let attemptID = UUID()
        remoteConnectionAttemptID = attemptID
        let clientBox = SendableRemoteClientBox(services.client)
        let fallbackLocation = preservedRemoteLocation(for: services.client)
        let shouldTryFallbackLocation = resolvedServer.defaultRemotePath != nil && fallbackLocation != nextLocation
        beginRemoteActivity()

        remoteWorkQueue.async {
            let result: Result<(RemoteDirectorySnapshot, RemoteLocation), Error>
            do {
                do {
                    let snapshot = try clientBox.client.loadDirectorySnapshot(in: nextLocation)
                    result = .success((snapshot, nextLocation))
                } catch {
                    if shouldTryFallbackLocation {
                        let fallbackSnapshot = try clientBox.client.loadDirectorySnapshot(in: fallbackLocation)
                        result = .success((fallbackSnapshot, fallbackLocation))
                    } else {
                        result = .failure(error)
                    }
                }
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.endRemoteActivity()
                guard attemptID == self.remoteConnectionAttemptID else { return }

                switch result {
                case .success(let payload):
                    let snapshot = payload.0
                    if let configuredLocalDirectoryURL = self.configuredLocalDirectoryURL(for: resolvedServer) {
                        self.setLocalDirectory(
                            configuredLocalDirectoryURL.standardizedFileURL,
                            securityScopeRoot: configuredLocalDirectoryURL.standardizedFileURL
                        )
                        self.reloadDirectory(in: .local, selecting: nil)
                    }
                    self.remoteLocation = snapshot.location
                    self.remoteHomePath = snapshot.homePath
                    self.remotePathDraft = snapshot.location.remotePath
                    self.remoteItems = snapshot.items
                    self.remoteErrorMessage = nil
                    self.selectedRemoteItemID = snapshot.items.first?.id
                    self.remoteSessionStatus = .connected("\(resolvedUsername)@\(resolvedHost)")
                    self.recordSuccessfulConnection(
                        for: resolvedServer,
                        summary: "\(resolvedUsername)@\(resolvedHost)"
                    )
                    self.showsConnectionSheet = false
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Connected to \(resolvedServer.name) via \(resolvedServer.connectionKind.title)."),
                        status: .completed
                    )
                case .failure(let error):
                    self.remoteItems = []
                    self.selectedRemoteItemID = nil
                    self.remoteErrorMessage = error.localizedDescription
                    self.remoteSessionStatus = .failed(error.localizedDescription)
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "\(resolvedServer.connectionKind.title) connection failed: \(error.localizedDescription)"),
                        status: .failed
                    )
                }
            }
        }
    }

    private func preservedRemoteLocation(for client: any RemoteClient) -> RemoteLocation {
        guard case .connected = remoteSessionStatus else {
            return client.makeInitialLocation(relativeTo: localDirectoryURL)
        }

        if let preservedRemoteDirectoryURL = remoteLocation.directoryURL {
            return client.makeLocation(for: preservedRemoteDirectoryURL)
        }

        return client.makeLocation(for: URL(fileURLWithPath: remoteLocation.remotePath))
    }

    private func initialRemoteLocation(for server: ServerProfile, client: any RemoteClient) -> RemoteLocation {
        if let defaultRemotePath = server.defaultRemotePath, !defaultRemotePath.isEmpty {
            return client.makeLocation(for: URL(fileURLWithPath: defaultRemotePath, isDirectory: true))
        }
        return preservedRemoteLocation(for: client)
    }

    func presentRemotePathSheet() {
        guard isRemoteConnected else { return }
        remotePathDraft = remoteLocation.remotePath
        showsRemotePathSheet = true
    }

    func jumpToRemoteHomeDirectory() {
        navigateToRemotePath("~")
    }

    func jumpToRemoteRootDirectory() {
        navigateToRemotePath("/")
    }

    func navigateToRemotePath(_ proposedPath: String) {
        guard isRemoteConnected else {
            transferFeedback = TransferFeedback(
                message: String(localized: "Connect a site before changing the remote folder."),
                status: .failed
            )
            return
        }

        guard let normalizedPath = normalizedRemotePathInput(proposedPath) else {
            transferFeedback = TransferFeedback(
                message: String(localized: "Enter a valid remote folder path."),
                status: .failed
            )
            return
        }

        let nextLocation = remoteClient.makeLocation(for: URL(fileURLWithPath: normalizedPath))
        remoteLocation = nextLocation
        remotePathDraft = normalizedPath
        selectedRemoteItemID = nil
        remoteErrorMessage = nil
        showsRemotePathSheet = false
        reloadRemoteDirectoryAsync(selecting: nil)
    }

    func beginRenamingFocusedSelection() {
        guard let item = selectedItem else { return }
        beginRenaming(itemID: item.id, in: focusedPane)
    }

    func beginRenaming(itemID: BrowserItem.ID, in pane: BrowserPane) {
        guard let item = item(for: pane, id: itemID) else { return }
        select(itemID: itemID, in: pane)
        renameRequest = RenameRequest(
            pane: pane,
            itemID: itemID,
            originalName: item.name,
            proposedName: item.name
        )
    }

    func submitRenameRequest() {
        guard let renameRequest, let item = item(for: renameRequest.pane, id: renameRequest.itemID) else {
            self.renameRequest = nil
            return
        }

        switch renameRequest.pane {
        case .local:
            guard let sourceURL = item.url else {
                self.renameRequest = nil
                return
            }

            do {
                let renamedURL = try localFileTransfer.renameItem(at: sourceURL, toName: renameRequest.proposedName)
                reloadDirectory(in: renameRequest.pane, selecting: renamedURL.path(percentEncoded: false))
                transferFeedback = TransferFeedback(
                    message: String(localized: "Renamed \(renameRequest.originalName) to \(renamedURL.lastPathComponent)."),
                    status: .completed
                )
            } catch {
                transferFeedback = TransferFeedback(
                    message: String(localized: "Rename failed: \(error.localizedDescription)"),
                    status: .failed
                )
            }
        case .remote:
            let clientBox = SendableRemoteClientBox(remoteClient)
            let originalName = renameRequest.originalName
            let remotePath = item.pathDescription
            let proposedName = renameRequest.proposedName
            beginRemoteActivity()
            remoteWorkQueue.async {
                let result: Result<RemoteMutationResult, Error>
                do {
                    result = .success(try clientBox.client.renameItem(
                        named: originalName,
                        at: remotePath,
                        to: proposedName
                    ))
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async {
                    self.endRemoteActivity()
                    switch result {
                    case .success(let mutation):
                        self.reloadRemoteDirectoryAsync(selecting: mutation.remoteItemID)
                        self.transferFeedback = TransferFeedback(
                            message: String(localized: "Renamed \(originalName) to \(mutation.destinationName) on Remote."),
                            status: .completed
                        )
                    case .failure(let error):
                        self.transferFeedback = TransferFeedback(
                            message: String(localized: "Rename failed: \(error.localizedDescription)"),
                            status: .failed
                        )
                    }
                }
            }
        }

        self.renameRequest = nil
    }

    func cancelRenameRequest() {
        renameRequest = nil
    }

    func requestDeleteFocusedSelection() {
        guard let item = selectedItem else { return }
        requestDelete(itemID: item.id, in: focusedPane)
    }

    func requestDelete(itemID: BrowserItem.ID, in pane: BrowserPane) {
        guard let item = item(for: pane, id: itemID) else { return }
        select(itemID: itemID, in: pane)
        deleteRequest = DeleteRequest(
            pane: pane,
            itemID: itemID,
            itemName: item.name
        )
    }

    func confirmDeleteRequest() {
        guard let deleteRequest, let item = item(for: deleteRequest.pane, id: deleteRequest.itemID) else {
            self.deleteRequest = nil
            return
        }

        self.deleteRequest = nil

        if item.isDirectory {
            switch deleteRequest.pane {
            case .local:
                guard let sourceURL = item.url else { return }
                if localFileTransfer.directoryHasContents(at: sourceURL) {
                    nonEmptyFolderDeleteRequest = NonEmptyFolderDeleteRequest(
                        pane: deleteRequest.pane,
                        itemID: deleteRequest.itemID,
                        itemName: deleteRequest.itemName
                    )
                    return
                }
                performLocalDelete(item: item, request: deleteRequest, recursively: false)
            case .remote:
                guard let location = remoteClient.location(for: item, from: remoteLocation) else {
                    performRemoteDelete(item: item, request: deleteRequest, recursively: false)
                    return
                }

                let clientBox = SendableRemoteClientBox(remoteClient)
                beginRemoteActivity()
                remoteWorkQueue.async {
                    let result: Result<Bool, Error>
                    do {
                        result = .success(try !clientBox.client.loadItems(in: location).isEmpty)
                    } catch {
                        result = .failure(error)
                    }

                    DispatchQueue.main.async {
                        self.endRemoteActivity()
                        switch result {
                        case .success(let hasContents):
                            if hasContents {
                                self.nonEmptyFolderDeleteRequest = NonEmptyFolderDeleteRequest(
                                    pane: deleteRequest.pane,
                                    itemID: deleteRequest.itemID,
                                    itemName: deleteRequest.itemName
                                )
                            } else {
                                self.performRemoteDelete(item: item, request: deleteRequest, recursively: false)
                            }
                        case .failure(let error):
                            self.transferFeedback = TransferFeedback(
                                message: String(localized: "Delete failed: \(error.localizedDescription)"),
                                status: .failed
                            )
                        }
                    }
                }
            }
            return
        }

        switch deleteRequest.pane {
        case .local:
            performLocalDelete(item: item, request: deleteRequest, recursively: false)
        case .remote:
            performRemoteDelete(item: item, request: deleteRequest, recursively: false)
        }
    }

    func cancelDeleteRequest() {
        deleteRequest = nil
    }

    func confirmNonEmptyFolderDeleteRequest() {
        guard
            let request = nonEmptyFolderDeleteRequest,
            let item = item(for: request.pane, id: request.itemID)
        else {
            nonEmptyFolderDeleteRequest = nil
            return
        }

        let deleteRequest = DeleteRequest(
            pane: request.pane,
            itemID: request.itemID,
            itemName: request.itemName
        )
        nonEmptyFolderDeleteRequest = nil

        switch request.pane {
        case .local:
            performLocalDelete(item: item, request: deleteRequest, recursively: true)
        case .remote:
            performRemoteDelete(item: item, request: deleteRequest, recursively: true)
        }
    }

    func cancelNonEmptyFolderDeleteRequest() {
        nonEmptyFolderDeleteRequest = nil
    }

    func submitCreateFolderRequest() {
        guard let createFolderRequest else { return }

        switch createFolderRequest.pane {
        case .local:
            do {
                let createdURL = try localFileTransfer.createDirectory(
                    named: createFolderRequest.proposedName,
                    in: localDirectoryURL
                )
                reloadDirectory(in: .local, selecting: createdURL.path(percentEncoded: false))
                transferFeedback = TransferFeedback(
                    message: String(localized: "Created folder \(createdURL.lastPathComponent) in Local."),
                    status: .completed
                )
            } catch {
                transferFeedback = TransferFeedback(
                    message: String(localized: "Create folder failed: \(error.localizedDescription)"),
                    status: .failed
                )
            }
        case .remote:
            let clientBox = SendableRemoteClientBox(remoteClient)
            let proposedName = createFolderRequest.proposedName
            let remoteLocation = remoteLocation
            beginRemoteActivity()
            remoteWorkQueue.async {
                let result: Result<RemoteMutationResult, Error>
                do {
                    result = .success(try clientBox.client.createDirectory(
                        named: proposedName,
                        in: remoteLocation
                    ))
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async {
                    self.endRemoteActivity()
                    switch result {
                    case .success(let mutation):
                        self.reloadRemoteDirectoryAsync(selecting: mutation.remoteItemID)
                        self.transferFeedback = TransferFeedback(
                            message: String(localized: "Created folder \(mutation.destinationName) in Remote."),
                            status: .completed
                        )
                    case .failure(let error):
                        self.transferFeedback = TransferFeedback(
                            message: String(localized: "Create folder failed: \(error.localizedDescription)"),
                            status: .failed
                        )
                    }
                }
            }
        }

        self.createFolderRequest = nil
    }

    func cancelCreateFolderRequest() {
        createFolderRequest = nil
    }

    func resolveTransferConflict(with policy: TransferConflictPolicy) {
        guard let pendingTransferLaunch else { return }
        transferConflictResolutionRequest = nil
        self.pendingTransferLaunch = nil

        switch pendingTransferLaunch {
        case .upload(let sourceURLs, let sourcePane, let targetItemID, let destination):
            uploadLocalItems(
                sourceURLs,
                from: sourcePane,
                targetItemID: targetItemID,
                destinationOverride: destination,
                conflictPolicy: policy
            )
        case .download(let items, let targetItemID, let destinationDirectoryURL):
            downloadRemoteItems(
                items,
                to: .local,
                targetItemID: targetItemID,
                destinationDirectoryOverride: destinationDirectoryURL,
                conflictPolicy: policy
            )
        }
    }

    func cancelTransferConflictResolution() {
        transferConflictResolutionRequest = nil
        pendingTransferLaunch = nil
    }

    func beginLocalDrag(items: [BrowserItem]) {
        activeLocalDragURLs = items.compactMap(\.url).map(\.standardizedFileURL)
    }

    func resolveLocalDragURLs(fallingBackTo droppedURLs: [URL]) -> [URL] {
        let normalizedDroppedURLs = droppedURLs.map(\.standardizedFileURL)
        defer { activeLocalDragURLs = [] }

        guard !activeLocalDragURLs.isEmpty else {
            return normalizedDroppedURLs
        }

        guard !normalizedDroppedURLs.isEmpty else {
            return activeLocalDragURLs
        }

        let activePaths = Set(activeLocalDragURLs.map { $0.path(percentEncoded: false) })
        let droppedPaths = Set(normalizedDroppedURLs.map { $0.path(percentEncoded: false) })
        guard !activePaths.isDisjoint(with: droppedPaths) else {
            return normalizedDroppedURLs
        }

        return activeLocalDragURLs
    }

    func selectLocalItem(id: BrowserItem.ID?) {
        selectedLocalItemID = id
        selectedLocalItemIDs = id.map { [$0] } ?? []
        if id != nil {
            selectedRemoteItemID = nil
            selectedRemoteItemIDs = []
            focusedPane = .local
        }
    }

    func selectRemoteItem(id: BrowserItem.ID?) {
        selectedRemoteItemID = id
        selectedRemoteItemIDs = id.map { [$0] } ?? []
        if id != nil {
            selectedLocalItemID = nil
            selectedLocalItemIDs = []
            focusedPane = .remote
        }
    }

    func selectLocalItems(ids: Set<BrowserItem.ID>) {
        selectedLocalItemIDs = ids
        if let selectedLocalItemID, ids.contains(selectedLocalItemID) {
            self.selectedLocalItemID = selectedLocalItemID
        } else {
            selectedLocalItemID = localItems.first(where: { ids.contains($0.id) })?.id
        }
        if !ids.isEmpty {
            selectedRemoteItemID = nil
            selectedRemoteItemIDs = []
            focusedPane = .local
        }
    }

    func selectRemoteItems(ids: Set<BrowserItem.ID>) {
        selectedRemoteItemIDs = ids
        if let selectedRemoteItemID, ids.contains(selectedRemoteItemID) {
            self.selectedRemoteItemID = selectedRemoteItemID
        } else {
            selectedRemoteItemID = remoteItems.first(where: { ids.contains($0.id) })?.id
        }
        if !ids.isEmpty {
            selectedLocalItemID = nil
            selectedLocalItemIDs = []
            focusedPane = .remote
        }
    }

    private func directoryURL(for pane: BrowserPane, targetItemID: BrowserItem.ID? = nil) -> URL {
        switch pane {
        case .local:
            if
                let targetItemID,
                let item = localItems.first(where: { $0.id == targetItemID }),
                item.isDirectory,
                let url = item.url
            {
                return url
            }
            return localDirectoryURL
        case .remote:
            return remoteClient.destinationDirectoryURL(for: remoteLocation) ?? localDirectoryURL
        }
    }

    private func item(for pane: BrowserPane, id: BrowserItem.ID) -> BrowserItem? {
        switch pane {
        case .local:
            return localItems.first(where: { $0.id == id })
        case .remote:
            return remoteItems.first(where: { $0.id == id })
        }
    }

    private func select(itemID: BrowserItem.ID?, in pane: BrowserPane) {
        switch pane {
        case .local:
            selectLocalItem(id: itemID)
        case .remote:
            selectRemoteItem(id: itemID)
        }
    }

    private func selectedItemID(for pane: BrowserPane) -> BrowserItem.ID? {
        switch pane {
        case .local:
            selectedLocalItemID
        case .remote:
            selectedRemoteItemID
        }
    }

    private func isLocalDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func makeResolvedServer() -> ServerProfile {
        if let selectedServer {
            return ServerProfile(
                id: selectedServer.id,
                name: connectionDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedServer.name : connectionDraft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                endpoint: connectionDraft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedServer.endpoint : connectionDraft.host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(connectionDraft.port) ?? selectedServer.port,
                username: connectionDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedServer.username : connectionDraft.username.trimmingCharacters(in: .whitespacesAndNewlines),
                connectionKind: connectionDraft.connectionKind,
                authenticationMode: connectionDraft.authenticationMode,
                privateKeyPath: normalizedKeyDraftPath(connectionDraft.privateKeyPath),
                privateKeyBookmarkData: connectionDraft.privateKeyBookmarkData,
                publicKeyPath: normalizedKeyDraftPath(connectionDraft.publicKeyPath),
                publicKeyBookmarkData: connectionDraft.publicKeyBookmarkData,
                addressPreference: connectionDraft.addressPreference,
                s3Region: normalizedS3RegionDraft(connectionDraft.s3Region),
                defaultLocalDirectoryPath: normalizedLocalDirectoryDraftPath(connectionDraft.defaultLocalDirectoryPath),
                defaultRemotePath: normalizedRemoteDirectoryDraftPath(connectionDraft.defaultRemotePath),
                systemImage: systemImage(for: connectionDraft.connectionKind),
                accentName: accentName(for: connectionDraft.connectionKind)
            )
        }

        let trimmedHost = connectionDraft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = connectionDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = connectionDraft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerProfile(
            name: trimmedName.isEmpty ? (trimmedHost.isEmpty ? "Quick Connect" : trimmedHost) : trimmedName,
            endpoint: trimmedHost,
            port: Int(connectionDraft.port) ?? defaultPort(for: connectionDraft.connectionKind),
            username: trimmedUsername,
            connectionKind: connectionDraft.connectionKind,
            authenticationMode: connectionDraft.authenticationMode,
            privateKeyPath: normalizedKeyDraftPath(connectionDraft.privateKeyPath),
            privateKeyBookmarkData: connectionDraft.privateKeyBookmarkData,
            publicKeyPath: normalizedKeyDraftPath(connectionDraft.publicKeyPath),
            publicKeyBookmarkData: connectionDraft.publicKeyBookmarkData,
            addressPreference: connectionDraft.addressPreference,
            s3Region: normalizedS3RegionDraft(connectionDraft.s3Region),
            defaultLocalDirectoryPath: normalizedLocalDirectoryDraftPath(connectionDraft.defaultLocalDirectoryPath),
            defaultRemotePath: normalizedRemoteDirectoryDraftPath(connectionDraft.defaultRemotePath),
            systemImage: systemImage(for: connectionDraft.connectionKind),
            accentName: accentName(for: connectionDraft.connectionKind)
        )
    }

    private func configuredLocalDirectoryURL(for server: ServerProfile) -> URL? {
        guard let path = server.defaultLocalDirectoryPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func normalizedLocalDirectoryDraftPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .path(percentEncoded: false)
    }

    private func normalizedKeyDraftPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // `standardizedFileURL` normalizes spelling only; unlike
        // `resolvingSymlinksInPath()`, it preserves a selected link path.
        return URL(fileURLWithPath: expandingCurrentUserHomeDirectory(in: trimmed))
            .standardizedFileURL
            .path(percentEncoded: false)
    }

    private func normalizedRemoteDirectoryDraftPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let standardized = NSString(string: trimmed).standardizingPath
        guard !standardized.isEmpty, standardized != "." else { return "/" }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func normalizedS3RegionDraft(_ region: String) -> String? {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func recordSuccessfulConnection(for server: ServerProfile, summary: String) {
        guard servers.contains(where: { $0.id == server.id }) else { return }

        siteUsageByServerID[server.id] = SiteUsageRecord(
            lastConnectedAt: Date(),
            lastConnectionSummary: summary
        )

        do {
            try siteUsageStore.saveUsage(siteUsageByServerID)
        } catch {
            // Keep in-memory usage even if persistence fails.
        }
    }

    private func resolvedPassword(for server: ServerProfile) -> String {
        if connectionDraft.clearsSavedPassword {
            return ""
        }

        let typedPassword = connectionDraft.password.trimmingCharacters(in: .newlines)
        if !typedPassword.isEmpty {
            return connectionDraft.password
        }

        return (try? credentialStore.password(for: server.id)) ?? ""
    }

    private func uniqueDuplicateServerName(for name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedName.isEmpty ? String(localized: "Copied Site") : "\(trimmedName) Copy"
        let existingNames = Set(servers.map(\.name))
        guard existingNames.contains(baseName) else { return baseName }

        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    private func defaultPort(for connectionKind: ConnectionKind) -> Int {
        switch connectionKind {
        case .sftp:
            return 22
        case .webdav:
            return 80
        case .cloud:
            return 443
        }
    }

    private func systemImage(for connectionKind: ConnectionKind) -> String {
        switch connectionKind {
        case .sftp:
            return "server.rack"
        case .webdav:
            return "network"
        case .cloud:
            return "icloud"
        }
    }

    private func accentName(for connectionKind: ConnectionKind) -> String {
        switch connectionKind {
        case .sftp:
            return "Orange"
        case .webdav:
            return "Blue"
        case .cloud:
            return "Green"
        }
    }

    private func prependTransferActivity(_ activity: TransferActivity) {
        recentTransfers.insert(activity, at: 0)
        if recentTransfers.count > 24 {
            recentTransfers.removeLast(recentTransfers.count - 24)
        }
    }

    private func replaceTransferActivity(id: UUID, with updatedActivity: TransferActivity) {
        guard let index = recentTransfers.firstIndex(where: { $0.id == id }) else {
            prependTransferActivity(updatedActivity)
            return
        }

        recentTransfers[index] = updatedActivity
    }

    private func setTransferControl(_ control: TransferControl, for id: UUID) {
        transferControls[id] = control
    }

    private func updateTransferCancellationController(_ controller: TransferCancellationController?, for id: UUID) {
        guard var control = transferControls[id] else { return }
        control.cancellationController = controller
        transferControls[id] = control
    }

    private func clearTransferControl(for id: UUID) {
        transferControls[id] = nil
    }

    private func copyItems(at sourceURLs: [URL], from sourcePane: BrowserPane?, to destinationPane: BrowserPane, targetItemID: BrowserItem.ID? = nil) {
        if destinationPane == .remote {
            uploadLocalItems(sourceURLs, from: sourcePane, targetItemID: targetItemID)
            return
        }

        let destinationDirectoryURL = directoryURL(for: destinationPane, targetItemID: targetItemID)
        var lastCopiedItemID: BrowserItem.ID?
        var copiedNames: [String] = []
        var renamedNames: [String] = []

        for sourceURL in sourceURLs {
            let activityID = UUID()
            let sourceName = sourceURL.lastPathComponent

            prependTransferActivity(
                .init(
                    id: activityID,
                    title: sourceName,
                    detail: String(localized: "Copying to \(destinationDirectoryURL.lastPathComponent)"),
                    progress: 0.35,
                    status: .running
                )
            )

            do {
                let result = try localFileTransfer.copyItem(at: sourceURL, toDirectory: destinationDirectoryURL)
                replaceTransferActivity(
                    id: activityID,
                    with: .init(
                        id: activityID,
                        title: result.destinationURL.lastPathComponent,
                        detail: sourcePane.map { String(localized: "Copied from \($0.title) to \(destinationPane.title)") }
                            ?? String(localized: "Dropped into \(destinationPane.title)"),
                        progress: 1.0,
                        status: .completed
                    )
                )

                copiedNames.append(result.destinationURL.lastPathComponent)
                if result.renamedForConflict {
                    renamedNames.append(result.destinationURL.lastPathComponent)
                }
                lastCopiedItemID = result.destinationURL.path(percentEncoded: false)
            } catch {
                replaceTransferActivity(
                    id: activityID,
                    with: .init(
                        id: activityID,
                        title: sourceName,
                        detail: error.localizedDescription,
                        progress: 1.0,
                        status: .failed
                    )
                )
                transferFeedback = TransferFeedback(
                    message: String(localized: "Copy failed: \(error.localizedDescription)"),
                    status: .failed
                )
            }
        }

        if let sourcePane {
            reloadDirectory(in: sourcePane, selecting: selectedItemID(for: sourcePane))
        }
        reloadDirectory(in: destinationPane, selecting: lastCopiedItemID)

        if !renamedNames.isEmpty {
            let renamedList = renamedNames.joined(separator: ", ")
            transferFeedback = TransferFeedback(
                message: String(localized: "Copied with renamed duplicates: \(renamedList)."),
                status: .completed
            )
        } else if !copiedNames.isEmpty {
            let summary = copiedNames.count == 1 ? copiedNames[0] : "\(copiedNames.count) items"
            transferFeedback = TransferFeedback(
                message: String(localized: "Copied \(summary) to \(destinationPane.title)."),
                status: .completed
            )
        }
    }

    private func uploadLocalItems(
        _ sourceURLs: [URL],
        from sourcePane: BrowserPane?,
        targetItemID: BrowserItem.ID? = nil,
        destinationOverride: RemoteLocation? = nil,
        conflictPolicy: TransferConflictPolicy? = nil
    ) {
        let remoteLocation = destinationOverride ?? remoteDropLocation(for: targetItemID) ?? remoteLocation
        if conflictPolicy == nil {
            do {
                let conflictingNames = try uploadConflictingNames(for: sourceURLs, at: remoteLocation)
                if !conflictingNames.isEmpty {
                    pendingTransferLaunch = .upload(
                        sourceURLs: sourceURLs,
                        sourcePane: sourcePane,
                        targetItemID: targetItemID,
                        destination: remoteLocation
                    )
                    transferConflictResolutionRequest = TransferConflictResolutionRequest(
                        operationTitle: String(localized: "Upload Conflict"),
                        destinationSummary: remoteLocation.path,
                        conflictingNames: conflictingNames
                    )
                    return
                }
            } catch {
                transferFeedback = TransferFeedback(
                    message: String(localized: "Unable to inspect remote destination: \(error.localizedDescription)"),
                    status: .failed
                )
                return
            }
        }

        let resolvedConflictPolicy = conflictPolicy ?? .rename
        let clientBox = SendableRemoteClientBox(remoteClient)
        let localSecurityScopeRootURL = self.localSecurityScopeRootURL
        let transferExecutionQueue = self.transferExecutionQueue
        let maxConcurrentTransfers = self.maxConcurrentTransfers

        beginRemoteActivity()
        remoteWorkQueue.async {
            var lastCopiedItemID: BrowserItem.ID?
            var copiedNames: [String] = []
            var renamedNames: [String] = []
            var cancelledNames: [String] = []
            var failedSourceURLs: [URL] = []
            var failureMessage: String?
            let accumulationLock = NSLock()
            let fileTransferGroup = DispatchGroup()
            let fileTransferSemaphore = DispatchSemaphore(value: maxConcurrentTransfers)
            let showsBatchSummary = sourceURLs.count > 1 || sourceURLs.contains(where: { ($0.hasDirectoryPath) })
            let batchActivityID = showsBatchSummary ? UUID() : nil
            let batchDestination = remoteLocation.path
            let initialBatchTitle = sourceURLs.count == 1 ? sourceURLs[0].lastPathComponent : nil
            var batchQueuedCount = 0

            if let batchActivityID {
                DispatchQueue.main.async {
                    self.prependTransferActivity(
                        .init(
                            id: batchActivityID,
                            title: transferBatchTitle(singleTitle: initialBatchTitle, itemCount: 0, itemLabel: "Uploads"),
                            detail: transferBatchProgressDetail(
                                operation: String(localized: "Upload"),
                                destination: batchDestination,
                                queuedCount: 0,
                                successCount: 0,
                                cancelledCount: 0,
                                failedCount: 0
                            ),
                            progress: 0,
                            status: .running
                        )
                    )
                }
            }

            func refreshBatchActivity(status: TransferStatus = .running) {
                guard let batchActivityID else { return }

                let queuedCount: Int
                let successCount: Int
                let cancelledCount: Int
                let failedCount: Int
                accumulationLock.lock()
                queuedCount = batchQueuedCount
                successCount = copiedNames.count
                cancelledCount = cancelledNames.count
                failedCount = failedSourceURLs.count
                accumulationLock.unlock()

                DispatchQueue.main.async {
                    self.replaceTransferActivity(
                        id: batchActivityID,
                        with: .init(
                            id: batchActivityID,
                            title: transferBatchTitle(singleTitle: initialBatchTitle, itemCount: queuedCount, itemLabel: "Uploads"),
                            detail: transferBatchProgressDetail(
                                operation: String(localized: "Upload"),
                                destination: batchDestination,
                                queuedCount: queuedCount,
                                successCount: successCount,
                                cancelledCount: cancelledCount,
                                failedCount: failedCount
                            ),
                            progress: queuedCount == 0 ? 0 : Double(successCount + cancelledCount + failedCount) / Double(queuedCount),
                            status: status
                        )
                    )
                }
            }

            func recordFailure(_ message: String) {
                accumulationLock.lock()
                if failureMessage == nil {
                    failureMessage = message
                }
                accumulationLock.unlock()
            }

            func recordSuccess(name: String, renamed: Bool, itemID: BrowserItem.ID) {
                accumulationLock.lock()
                copiedNames.append(name)
                if renamed {
                    renamedNames.append(name)
                }
                lastCopiedItemID = itemID
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func recordCancellation(name: String) {
                accumulationLock.lock()
                cancelledNames.append(name)
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func recordFailedSourceURL(_ sourceURL: URL) {
                accumulationLock.lock()
                failedSourceURLs.append(sourceURL)
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func recordQueuedBatchItem() {
                accumulationLock.lock()
                batchQueuedCount += 1
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func withScopedLocalAccess<T>(_ sourceURL: URL, operation: () throws -> T) throws -> T {
                if
                    let localSecurityScopeRootURL,
                    sourceURL.path(percentEncoded: false).hasPrefix(localSecurityScopeRootURL.path(percentEncoded: false))
                {
                    return try withSecurityScopedAccess(to: localSecurityScopeRootURL, operation: operation)
                }
                return try operation()
            }

            func sortedChildURLs(in directoryURL: URL) throws -> [URL] {
                try FileManager.default
                    .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    .sorted { lhs, rhs in
                        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
                }
            }

            func enqueueUploadFile(at sourceURL: URL, to destination: RemoteLocation) {
                let activityID = UUID()
                let sourceName = sourceURL.lastPathComponent
                let cancellationController = TransferCancellationController()
                let pauseController = TransferPauseController()
                recordQueuedBatchItem()

                DispatchQueue.main.async {
                    self.prependTransferActivity(
                        .init(
                            id: activityID,
                            title: sourceName,
                            detail: String(localized: "Queued for upload to \(destination.path)"),
                            progress: 0,
                            status: .queued
                        )
                    )
                    self.setTransferControl(
                        .init(
                            cancellationController: cancellationController,
                            pauseController: pauseController,
                            retryDescriptor: .uploadFile(sourceURL: sourceURL, destination: destination)
                        ),
                        for: activityID
                    )
                }

                fileTransferGroup.enter()
                transferExecutionQueue.async {
                    fileTransferSemaphore.wait()
                    defer {
                        fileTransferSemaphore.signal()
                        fileTransferGroup.leave()
                    }

                    do {
                        if cancellationController.isCancelled {
                            recordCancellation(name: sourceName)
                            DispatchQueue.main.async {
                                self.replaceTransferActivity(
                                    id: activityID,
                                    with: .init(
                                        id: activityID,
                                        title: sourceName,
                                        detail: String(localized: "Cancelled before transfer started."),
                                        progress: 0,
                                        status: .cancelled
                                    )
                                )
                                self.updateTransferCancellationController(nil, for: activityID)
                            }
                            return
                        }

                        try pauseController.waitWhilePaused(isCancelled: { cancellationController.isCancelled })

                        let sourceByteCount = try resolvedByteCount(for: sourceURL)
                        var uploadResult: RemoteUploadResult?

                        DispatchQueue.main.async {
                            self.replaceTransferActivity(
                                id: activityID,
                                with: .init(
                                    id: activityID,
                                    title: sourceName,
                                    detail: transferProgressDetail(
                                        prefix: "Uploading to \(destination.path)",
                                        progress: .init(completedByteCount: 0, totalByteCount: sourceByteCount)
                                    ),
                                    progress: 0,
                                    status: .running
                                )
                            )
                        }

                        try withScopedLocalAccess(sourceURL) {
                            let performUpload = {
                                try withSecurityScopedAccess(to: sourceURL) {
                                    let stagedURL = try stageUploadSource(at: sourceURL)
                                    defer { try? FileManager.default.removeItem(at: stagedURL) }
                                    let result = try clientBox.client.uploadItem(
                                        at: stagedURL,
                                        to: destination,
                                        conflictPolicy: resolvedConflictPolicy,
                                        progress: { snapshot in
                                            do {
                                                try pauseController.waitWhilePaused(isCancelled: { cancellationController.isCancelled })
                                            } catch {
                                                cancellationController.cancel()
                                            }
                                            DispatchQueue.main.async {
                                                self.replaceTransferActivity(
                                                    id: activityID,
                                                    with: .init(
                                                        id: activityID,
                                                        title: sourceName,
                                                        detail: transferProgressDetail(
                                                            prefix: "Uploading to \(destination.path)",
                                                            progress: snapshot
                                                        ),
                                                        progress: snapshot.fractionCompleted,
                                                        status: .running
                                                    )
                                                )
                                            }
                                        },
                                        isCancelled: { cancellationController.isCancelled }
                                    )
                                    uploadResult = result
                                }
                            }
                            try performUpload()
                        }

                        guard let result = uploadResult else {
                            throw CocoaError(.fileWriteUnknown)
                        }

                        recordSuccess(
                            name: result.destinationName,
                            renamed: result.renamedForConflict,
                            itemID: result.remoteItemID
                        )

                        DispatchQueue.main.async {
                            self.replaceTransferActivity(
                                id: activityID,
                                with: .init(
                                    id: activityID,
                                    title: result.destinationName,
                                    detail: String(localized: "Uploaded to Remote"),
                                    progress: 1.0,
                                    status: .completed
                                )
                            )
                            self.updateTransferCancellationController(nil, for: activityID)
                        }
                    } catch is CancellationError {
                        recordCancellation(name: sourceName)
                        DispatchQueue.main.async {
                            self.replaceTransferActivity(
                                id: activityID,
                                with: .init(
                                    id: activityID,
                                    title: sourceName,
                                    detail: String(localized: "Transfer cancelled."),
                                    progress: 1.0,
                                    status: .cancelled
                                )
                            )
                            self.updateTransferCancellationController(nil, for: activityID)
                        }
                    } catch {
                        if isTransferCancellationError(error) {
                            recordCancellation(name: sourceName)
                            DispatchQueue.main.async {
                                self.replaceTransferActivity(
                                    id: activityID,
                                    with: .init(
                                        id: activityID,
                                        title: sourceName,
                                        detail: String(localized: "Transfer cancelled."),
                                        progress: 1.0,
                                        status: .cancelled
                                    )
                                )
                                self.updateTransferCancellationController(nil, for: activityID)
                            }
                        } else {
                            recordFailure(error.localizedDescription)
                            recordFailedSourceURL(sourceURL)
                            DispatchQueue.main.async {
                                self.replaceTransferActivity(
                                    id: activityID,
                                    with: .init(
                                        id: activityID,
                                        title: sourceName,
                                        detail: error.localizedDescription,
                                        progress: 1.0,
                                        status: .failed
                                    )
                                )
                                self.updateTransferCancellationController(nil, for: activityID)
                            }
                        }
                    }
                }
            }

            func uploadTree(at sourceURL: URL, to destination: RemoteLocation) throws {
                let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory == true {
                    let activityID = UUID()
                    let directoryName = sourceURL.lastPathComponent
                    recordQueuedBatchItem()
                    DispatchQueue.main.async {
                        self.prependTransferActivity(
                            .init(
                                id: activityID,
                                title: directoryName,
                                detail: String(localized: "Creating folder on \(destination.path)"),
                                progress: 0.2,
                                status: .running
                            )
                        )
                    }

                    let mutation = try clientBox.client.createDirectory(
                        named: directoryName,
                        in: destination,
                        conflictPolicy: resolvedConflictPolicy
                    )
                    let nestedLocation = clientBox.client.makeLocation(for: URL(fileURLWithPath: mutation.remoteItemID))
                    recordSuccess(
                        name: mutation.destinationName,
                        renamed: mutation.destinationName != directoryName,
                        itemID: mutation.remoteItemID
                    )

                    DispatchQueue.main.async {
                        self.replaceTransferActivity(
                            id: activityID,
                            with: .init(
                                id: activityID,
                                title: mutation.destinationName,
                                detail: String(localized: "Created folder on Remote"),
                                progress: 1.0,
                                status: .completed
                            )
                        )
                    }

                    let childURLs = try withScopedLocalAccess(sourceURL) {
                        try sortedChildURLs(in: sourceURL)
                    }
                    for childURL in childURLs {
                        try uploadTree(at: childURL, to: nestedLocation)
                    }
                    return
                }

                enqueueUploadFile(at: sourceURL, to: destination)
            }

            for sourceURL in sourceURLs {
                do {
                    try uploadTree(at: sourceURL, to: remoteLocation)
                } catch {
                    if isTransferCancellationError(error) {
                        recordCancellation(name: sourceURL.lastPathComponent)
                    } else {
                        recordFailure(error.localizedDescription)
                        recordFailedSourceURL(sourceURL)
                    }
                }
            }

            fileTransferGroup.wait()

            DispatchQueue.main.async {
                self.endRemoteActivity()
                if let sourcePane {
                    self.reloadDirectory(in: sourcePane, selecting: self.selectedItemID(for: sourcePane))
                }
                self.reloadRemoteDirectoryAsync(selecting: lastCopiedItemID)

                        if let batchActivityID {
                            let batchStatus: TransferStatus
                            let batchMessage: String

                            if !failedSourceURLs.isEmpty {
                                batchStatus = .failed
                                batchMessage = transferBatchDetail(
                                    operation: String(localized: "Upload"),
                                    successCount: copiedNames.count,
                                    cancelledCount: cancelledNames.count,
                                    failedCount: failedSourceURLs.count
                        )
                        self.setTransferControl(
                            .init(
                                retryDescriptor: .uploadBatch(
                                    sourceURLs: failedSourceURLs,
                                    destination: remoteLocation
                                )
                            ),
                            for: batchActivityID
                        )
                    } else if !cancelledNames.isEmpty && copiedNames.isEmpty {
                        batchStatus = .cancelled
                        batchMessage = transferBatchDetail(
                            operation: String(localized: "Upload"),
                            successCount: 0,
                            cancelledCount: cancelledNames.count,
                            failedCount: 0
                        )
                    } else {
                        batchStatus = .completed
                        batchMessage = transferBatchDetail(
                            operation: String(localized: "Upload"),
                            successCount: copiedNames.count,
                            cancelledCount: cancelledNames.count,
                            failedCount: 0
                        )
                    }

                    self.replaceTransferActivity(
                        id: batchActivityID,
                        with: .init(
                            id: batchActivityID,
                            title: transferBatchTitle(singleTitle: initialBatchTitle, itemCount: batchQueuedCount, itemLabel: "Uploads"),
                            detail: batchMessage,
                            progress: 1.0,
                            status: batchStatus
                        )
                    )
                }

                if let failureMessage {
                    let prefix = failedSourceURLs.count > 1
                        ? String(localized: "Upload batch completed with failures.")
                        : String(localized: "Upload failed: \(failureMessage)")
                    self.transferFeedback = TransferFeedback(message: prefix, status: .failed)
                } else if !cancelledNames.isEmpty && copiedNames.isEmpty {
                    let summary = cancelledNames.count == 1 ? cancelledNames[0] : "\(cancelledNames.count) items"
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Cancelled upload for \(summary)."),
                        status: .cancelled
                    )
                } else if !renamedNames.isEmpty {
                    let summary = renamedNames.joined(separator: ", ")
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Copied with renamed duplicates: \(summary)."),
                        status: .completed
                    )
                } else if !copiedNames.isEmpty {
                    let summary = copiedNames.count == 1 ? copiedNames[0] : "\(copiedNames.count) items"
                    let cancelledSuffix = cancelledNames.isEmpty ? "" : " (\(cancelledNames.count) cancelled)"
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Uploaded \(summary) to Remote\(cancelledSuffix)."),
                        status: .completed
                    )
                }
            }
        }
    }

    private func downloadRemoteItems(
        _ items: [BrowserItem],
        to destinationPane: BrowserPane,
        targetItemID: BrowserItem.ID? = nil,
        destinationDirectoryOverride: URL? = nil,
        conflictPolicy: TransferConflictPolicy? = nil
    ) {
        guard destinationPane == .local else { return }
        let clientBox = SendableRemoteClientBox(remoteClient)
        let localDirectoryURL = destinationDirectoryOverride ?? directoryURL(for: destinationPane, targetItemID: targetItemID)
        if conflictPolicy == nil {
            let conflictingNames = downloadConflictingNames(for: items, in: localDirectoryURL)
            if !conflictingNames.isEmpty {
                pendingTransferLaunch = .download(
                    items: items,
                    targetItemID: targetItemID,
                    destinationDirectoryURL: localDirectoryURL
                )
                transferConflictResolutionRequest = TransferConflictResolutionRequest(
                    operationTitle: String(localized: "Download Conflict"),
                    destinationSummary: localDirectoryURL.path(percentEncoded: false),
                    conflictingNames: conflictingNames
                )
                return
            }
        }

        let resolvedConflictPolicy = conflictPolicy ?? .rename
        let localFileTransfer = localFileTransfer
        let transferExecutionQueue = self.transferExecutionQueue
        let maxConcurrentTransfers = self.maxConcurrentTransfers

        beginRemoteActivity()
        remoteWorkQueue.async {
            var lastCopiedItemID: BrowserItem.ID?
            var copiedNames: [String] = []
            var renamedNames: [String] = []
            var cancelledNames: [String] = []
            var failedItems: [BrowserItem] = []
            var failureMessage: String?
            let accumulationLock = NSLock()
            let fileTransferGroup = DispatchGroup()
            let fileTransferSemaphore = DispatchSemaphore(value: maxConcurrentTransfers)
            let showsBatchSummary = items.count > 1 || items.contains(where: \.isDirectory)
            let batchActivityID = showsBatchSummary ? UUID() : nil
            let batchDestination = localDirectoryURL.lastPathComponent
            let initialBatchTitle = items.count == 1 ? items[0].name : nil
            var batchQueuedCount = 0

            if let batchActivityID {
                DispatchQueue.main.async {
                    self.prependTransferActivity(
                        .init(
                            id: batchActivityID,
                            title: transferBatchTitle(singleTitle: initialBatchTitle, itemCount: 0, itemLabel: "Downloads"),
                            detail: transferBatchProgressDetail(
                                operation: String(localized: "Download"),
                                destination: batchDestination,
                                queuedCount: 0,
                                successCount: 0,
                                cancelledCount: 0,
                                failedCount: 0
                            ),
                            progress: 0,
                            status: .running
                        )
                    )
                }
            }

            func refreshBatchActivity(status: TransferStatus = .running) {
                guard let batchActivityID else { return }

                let queuedCount: Int
                let successCount: Int
                let cancelledCount: Int
                let failedCount: Int
                accumulationLock.lock()
                queuedCount = batchQueuedCount
                successCount = copiedNames.count
                cancelledCount = cancelledNames.count
                failedCount = failedItems.count
                accumulationLock.unlock()

                DispatchQueue.main.async {
                    self.replaceTransferActivity(
                        id: batchActivityID,
                        with: .init(
                            id: batchActivityID,
                            title: transferBatchTitle(singleTitle: initialBatchTitle, itemCount: queuedCount, itemLabel: "Downloads"),
                            detail: transferBatchProgressDetail(
                                operation: String(localized: "Download"),
                                destination: batchDestination,
                                queuedCount: queuedCount,
                                successCount: successCount,
                                cancelledCount: cancelledCount,
                                failedCount: failedCount
                            ),
                            progress: queuedCount == 0 ? 0 : Double(successCount + cancelledCount + failedCount) / Double(queuedCount),
                            status: status
                        )
                    )
                }
            }

            func recordFailure(_ message: String) {
                accumulationLock.lock()
                if failureMessage == nil {
                    failureMessage = message
                }
                accumulationLock.unlock()
            }

            func recordSuccess(name: String, renamed: Bool, itemID: BrowserItem.ID) {
                accumulationLock.lock()
                copiedNames.append(name)
                if renamed {
                    renamedNames.append(name)
                }
                lastCopiedItemID = itemID
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func recordCancellation(name: String) {
                accumulationLock.lock()
                cancelledNames.append(name)
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func recordFailedItem(_ item: BrowserItem) {
                accumulationLock.lock()
                failedItems.append(item)
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func recordQueuedBatchItem() {
                accumulationLock.lock()
                batchQueuedCount += 1
                accumulationLock.unlock()
                refreshBatchActivity()
            }

            func downloadTree(_ item: BrowserItem, into directoryURL: URL) throws {
                let activityID = UUID()
                let activityTitle = item.name
                let cancellationController = item.isDirectory ? nil : TransferCancellationController()
                let pauseController = item.isDirectory ? nil : TransferPauseController()
                recordQueuedBatchItem()

                DispatchQueue.main.async {
                    self.prependTransferActivity(
                        .init(
                            id: activityID,
                            title: activityTitle,
                            detail: item.isDirectory
                                ? String(localized: "Preparing folder for download")
                                : String(localized: "Queued for download to \(directoryURL.lastPathComponent)"),
                            progress: item.isDirectory ? 0.2 : 0,
                            status: item.isDirectory ? .running : .queued
                        )
                    )
                    if let cancellationController {
                        self.setTransferControl(
                            .init(
                                cancellationController: cancellationController,
                                pauseController: pauseController,
                                retryDescriptor: .downloadFile(item: item, destinationDirectoryURL: directoryURL)
                            ),
                            for: activityID
                        )
                    }
                }

                do {
                    if item.isDirectory {
                        let destinationURL = try localFileTransfer.createDirectory(
                            named: item.name,
                            in: directoryURL,
                            uniquingIfNeeded: true
                        )
                        recordSuccess(
                            name: destinationURL.lastPathComponent,
                            renamed: destinationURL.lastPathComponent != item.name,
                            itemID: destinationURL.path(percentEncoded: false)
                        )

                        DispatchQueue.main.async {
                            self.replaceTransferActivity(
                                id: activityID,
                                with: .init(
                                    id: activityID,
                                    title: destinationURL.lastPathComponent,
                                    detail: String(localized: "Created folder in Local"),
                                    progress: 1.0,
                                    status: .completed
                                )
                            )
                        }

                        let location = clientBox.client.makeLocation(for: URL(fileURLWithPath: item.pathDescription))
                        let snapshot = try clientBox.client.loadDirectorySnapshot(in: location)
                        for child in snapshot.items {
                            try downloadTree(child, into: destinationURL)
                        }
                    } else {
                        fileTransferGroup.enter()
                        transferExecutionQueue.async {
                            fileTransferSemaphore.wait()
                            defer {
                                fileTransferSemaphore.signal()
                                fileTransferGroup.leave()
                            }

                            do {
                                if cancellationController?.isCancelled == true {
                                    recordCancellation(name: activityTitle)
                                    DispatchQueue.main.async {
                                        self.replaceTransferActivity(
                                            id: activityID,
                                            with: .init(
                                                id: activityID,
                                                title: activityTitle,
                                                detail: String(localized: "Cancelled before transfer started."),
                                                progress: 0,
                                                status: .cancelled
                                            )
                                        )
                                        self.updateTransferCancellationController(nil, for: activityID)
                                    }
                                    return
                                }

                                try pauseController?.waitWhilePaused(isCancelled: { cancellationController?.isCancelled == true })

                                let totalByteCount = item.byteCount
                                DispatchQueue.main.async {
                                    self.replaceTransferActivity(
                                        id: activityID,
                                        with: .init(
                                            id: activityID,
                                            title: activityTitle,
                                            detail: transferProgressDetail(
                                                prefix: "Downloading to \(directoryURL.lastPathComponent)",
                                                progress: .init(completedByteCount: 0, totalByteCount: totalByteCount)
                                            ),
                                            progress: 0,
                                            status: .running
                                        )
                                    )
                                }

                                let result = try clientBox.client.downloadItem(
                                    named: item.name,
                                    at: item.pathDescription,
                                    toDirectory: directoryURL,
                                    localFileTransfer: localFileTransfer,
                                    conflictPolicy: resolvedConflictPolicy,
                                    progress: { snapshot in
                                        do {
                                            try pauseController?.waitWhilePaused(isCancelled: { cancellationController?.isCancelled == true })
                                        } catch {
                                            cancellationController?.cancel()
                                        }
                                        DispatchQueue.main.async {
                                            self.replaceTransferActivity(
                                                id: activityID,
                                                with: .init(
                                                    id: activityID,
                                                    title: activityTitle,
                                                    detail: transferProgressDetail(
                                                        prefix: "Downloading to \(directoryURL.lastPathComponent)",
                                                        progress: snapshot
                                                    ),
                                                    progress: snapshot.fractionCompleted,
                                                    status: .running
                                                )
                                            )
                                        }
                                    },
                                    isCancelled: { cancellationController?.isCancelled == true }
                                )
                                recordSuccess(
                                    name: result.destinationURL.lastPathComponent,
                                    renamed: result.renamedForConflict,
                                    itemID: result.destinationURL.path(percentEncoded: false)
                                )

                                DispatchQueue.main.async {
                                    self.replaceTransferActivity(
                                        id: activityID,
                                        with: .init(
                                            id: activityID,
                                            title: result.destinationURL.lastPathComponent,
                                            detail: String(localized: "Copied from Remote to Local"),
                                            progress: 1.0,
                                            status: .completed
                                        )
                                    )
                                    self.updateTransferCancellationController(nil, for: activityID)
                                }
                            } catch is CancellationError {
                                recordCancellation(name: activityTitle)
                                DispatchQueue.main.async {
                                    self.replaceTransferActivity(
                                        id: activityID,
                                        with: .init(
                                            id: activityID,
                                            title: activityTitle,
                                            detail: String(localized: "Transfer cancelled."),
                                            progress: 1.0,
                                            status: .cancelled
                                        )
                                    )
                                    self.updateTransferCancellationController(nil, for: activityID)
                                }
                            } catch {
                                if isTransferCancellationError(error) {
                                    recordCancellation(name: activityTitle)
                                    DispatchQueue.main.async {
                                        self.replaceTransferActivity(
                                            id: activityID,
                                            with: .init(
                                                id: activityID,
                                                title: activityTitle,
                                                detail: String(localized: "Transfer cancelled."),
                                                progress: 1.0,
                                                status: .cancelled
                                            )
                                        )
                                        self.updateTransferCancellationController(nil, for: activityID)
                                    }
                                } else {
                                    recordFailure(error.localizedDescription)
                                    recordFailedItem(item)
                                    DispatchQueue.main.async {
                                        self.replaceTransferActivity(
                                            id: activityID,
                                            with: .init(
                                                id: activityID,
                                                title: activityTitle,
                                                detail: error.localizedDescription,
                                                progress: 1.0,
                                                status: .failed
                                            )
                                        )
                                        self.updateTransferCancellationController(nil, for: activityID)
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    if isTransferCancellationError(error) {
                        recordCancellation(name: activityTitle)
                        DispatchQueue.main.async {
                            self.replaceTransferActivity(
                                id: activityID,
                                with: .init(
                                    id: activityID,
                                    title: activityTitle,
                                    detail: String(localized: "Transfer cancelled."),
                                    progress: 1.0,
                                    status: .cancelled
                                )
                            )
                            self.updateTransferCancellationController(nil, for: activityID)
                        }
                    } else {
                        recordFailure(error.localizedDescription)
                        recordFailedItem(item)
                        DispatchQueue.main.async {
                            self.replaceTransferActivity(
                                id: activityID,
                                with: .init(
                                    id: activityID,
                                    title: activityTitle,
                                    detail: error.localizedDescription,
                                    progress: 1.0,
                                    status: .failed
                                )
                            )
                        }
                    }
                }
            }

            for item in items {
                do {
                    try downloadTree(item, into: localDirectoryURL)
                } catch {
                    if isTransferCancellationError(error) {
                        recordCancellation(name: item.name)
                    } else {
                        recordFailure(error.localizedDescription)
                        recordFailedItem(item)
                    }
                }
            }

            fileTransferGroup.wait()

            DispatchQueue.main.async {
                self.endRemoteActivity()
                self.reloadDirectory(in: .local, selecting: lastCopiedItemID)
                self.reloadRemoteDirectoryAsync(selecting: self.selectedRemoteItemID)

                if let batchActivityID {
                    let batchStatus: TransferStatus
                    let batchMessage: String

                    if !failedItems.isEmpty {
                        batchStatus = .failed
                        batchMessage = transferBatchDetail(
                            operation: String(localized: "Download"),
                            successCount: copiedNames.count,
                            cancelledCount: cancelledNames.count,
                            failedCount: failedItems.count
                        )
                        self.setTransferControl(
                            .init(
                                retryDescriptor: .downloadBatch(
                                    items: failedItems,
                                    destinationDirectoryURL: localDirectoryURL
                                )
                            ),
                            for: batchActivityID
                        )
                    } else if !cancelledNames.isEmpty && copiedNames.isEmpty {
                        batchStatus = .cancelled
                        batchMessage = transferBatchDetail(
                            operation: String(localized: "Download"),
                            successCount: 0,
                            cancelledCount: cancelledNames.count,
                            failedCount: 0
                        )
                    } else {
                        batchStatus = .completed
                        batchMessage = transferBatchDetail(
                            operation: String(localized: "Download"),
                            successCount: copiedNames.count,
                            cancelledCount: cancelledNames.count,
                            failedCount: 0
                        )
                    }

                    self.replaceTransferActivity(
                        id: batchActivityID,
                        with: .init(
                            id: batchActivityID,
                            title: transferBatchTitle(singleTitle: initialBatchTitle, itemCount: batchQueuedCount, itemLabel: "Downloads"),
                            detail: batchMessage,
                            progress: 1.0,
                            status: batchStatus
                        )
                    )
                }

                if let failureMessage {
                    let prefix = failedItems.count > 1
                        ? String(localized: "Download batch completed with failures.")
                        : String(localized: "Download failed: \(failureMessage)")
                    self.transferFeedback = TransferFeedback(message: prefix, status: .failed)
                } else if !cancelledNames.isEmpty && copiedNames.isEmpty {
                    let summary = cancelledNames.count == 1 ? cancelledNames[0] : "\(cancelledNames.count) items"
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Cancelled download for \(summary)."),
                        status: .cancelled
                    )
                } else if !renamedNames.isEmpty {
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Downloaded with renamed duplicates: \(renamedNames.joined(separator: ", "))."),
                        status: .completed
                    )
                } else if !copiedNames.isEmpty {
                    let summary = copiedNames.count == 1 ? copiedNames[0] : "\(copiedNames.count) items"
                    let cancelledSuffix = cancelledNames.isEmpty ? "" : " (\(cancelledNames.count) cancelled)"
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Downloaded \(summary) to Local\(cancelledSuffix)."),
                        status: .completed
                    )
                }
            }
        }
    }

    private func retryUploadTransfer(sourceURL: URL, destination: RemoteLocation) {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            transferFeedback = TransferFeedback(
                message: String(localized: "Retry failed: source file no longer exists."),
                status: .failed
            )
            return
        }
        uploadLocalItems([sourceURL], from: nil, destinationOverride: destination)
    }

    private func retryDownloadTransfer(item: BrowserItem, destinationDirectoryURL: URL) {
        guard FileManager.default.fileExists(atPath: destinationDirectoryURL.path(percentEncoded: false)) else {
            transferFeedback = TransferFeedback(
                message: String(localized: "Retry failed: destination folder no longer exists."),
                status: .failed
            )
            return
        }
        downloadRemoteItems([item], to: .local, destinationDirectoryOverride: destinationDirectoryURL)
    }

    private func uploadConflictingNames(for sourceURLs: [URL], at destination: RemoteLocation) throws -> [String] {
        let siblingNames: Set<String>
        if destination.id == remoteLocation.id {
            siblingNames = Set(remoteItems.map(\.name))
        } else {
            siblingNames = Set(try remoteClient.loadItems(in: destination).map(\.name))
        }

        return sourceURLs
            .map(\.lastPathComponent)
            .filter { siblingNames.contains($0) }
            .uniquedPreservingOrder()
    }

    private func downloadConflictingNames(for items: [BrowserItem], in directoryURL: URL) -> [String] {
        items
            .map(\.name)
            .filter { FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0).path(percentEncoded: false)) }
            .uniquedPreservingOrder()
    }

    private func reloadDirectory(in pane: BrowserPane, selecting preferredID: BrowserItem.ID?) {
        do {
            let items: [BrowserItem]
            switch pane {
            case .local:
                items = sortItems(try withLocalDirectoryAccess {
                    try localFileBrowser.loadItems(in: localDirectoryURL)
                }, using: localBrowserSort)
            case .remote:
                let snapshot = try remoteClient.loadDirectorySnapshot(in: remoteLocation)
                remoteLocation = snapshot.location
                remoteHomePath = snapshot.homePath
                remotePathDraft = snapshot.location.remotePath
                items = sortItems(snapshot.items, using: remoteBrowserSort)
            }

            switch pane {
            case .local:
                localItems = items
                localErrorMessage = nil
                if let preferredID, items.contains(where: { $0.id == preferredID }) {
                    selectedLocalItemID = preferredID
                    selectedLocalItemIDs = [preferredID]
                } else {
                    selectedLocalItemID = items.first?.id
                    selectedLocalItemIDs = items.first.map { [$0.id] } ?? []
                }
            case .remote:
                remoteItems = items
                remoteErrorMessage = nil
                if let preferredID, items.contains(where: { $0.id == preferredID }) {
                    selectedRemoteItemID = preferredID
                    selectedRemoteItemIDs = [preferredID]
                } else {
                    selectedRemoteItemID = items.first?.id
                    selectedRemoteItemIDs = items.first.map { [$0.id] } ?? []
                }
            }
        } catch {
            switch pane {
            case .local:
                localItems = []
                selectedLocalItemID = nil
                selectedLocalItemIDs = []
                localErrorMessage = error.localizedDescription
            case .remote:
                remoteItems = []
                selectedRemoteItemID = nil
                selectedRemoteItemIDs = []
                remoteErrorMessage = error.localizedDescription
            }
        }
    }

    private func reloadRemoteDirectoryAsync(selecting preferredID: BrowserItem.ID?) {
        let clientBox = SendableRemoteClientBox(remoteClient)
        let location = remoteLocation
        let attemptID = UUID()
        remoteConnectionAttemptID = attemptID
        beginRemoteActivity()

        remoteWorkQueue.async {
            let result: Result<RemoteDirectorySnapshot, Error>
            do {
                result = .success(try clientBox.client.loadDirectorySnapshot(in: location))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.endRemoteActivity()
                guard attemptID == self.remoteConnectionAttemptID else { return }

                switch result {
                case .success(let snapshot):
                    self.remoteLocation = snapshot.location
                    self.remoteHomePath = snapshot.homePath
                    self.remotePathDraft = snapshot.location.remotePath
                    self.remoteItems = self.sortItems(snapshot.items, using: self.remoteBrowserSort)
                    self.remoteErrorMessage = nil
                    if let preferredID, self.remoteItems.contains(where: { $0.id == preferredID }) {
                        self.selectedRemoteItemID = preferredID
                        self.selectedRemoteItemIDs = [preferredID]
                    } else {
                        self.selectedRemoteItemID = self.remoteItems.first?.id
                        self.selectedRemoteItemIDs = self.remoteItems.first.map { [$0.id] } ?? []
                    }
                case .failure(let error):
                    self.remoteItems = []
                    self.selectedRemoteItemID = nil
                    self.selectedRemoteItemIDs = []
                    self.remoteErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func remoteDropLocation(for targetItemID: BrowserItem.ID?) -> RemoteLocation? {
        guard
            let targetItemID,
            let item = remoteItems.first(where: { $0.id == targetItemID }),
            item.isDirectory
        else {
            return nil
        }

        return remoteClient.location(for: item, from: remoteLocation)
    }

    private func normalizedRemotePathInput(_ proposedPath: String) -> String? {
        let trimmed = proposedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolvedPath: String
        if trimmed == "~" {
            resolvedPath = remoteHomePath ?? remoteLocation.remotePath
        } else if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            let basePath = remoteHomePath ?? remoteLocation.remotePath
            resolvedPath = suffix.isEmpty ? basePath : "\(basePath)/\(suffix)"
        } else if trimmed.hasPrefix("/") {
            resolvedPath = trimmed
        } else {
            resolvedPath = "\(remoteLocation.remotePath)/\(trimmed)"
        }

        let standardized = NSString(string: resolvedPath).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func performLocalDelete(item: BrowserItem, request: DeleteRequest, recursively: Bool) {
        guard let sourceURL = item.url else { return }

        do {
            try localFileTransfer.deleteItem(at: sourceURL, recursively: recursively)
            reloadDirectory(in: request.pane, selecting: nil)
            transferFeedback = TransferFeedback(
                message: String(localized: "Deleted \(request.itemName)."),
                status: .completed
            )
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Delete failed: \(error.localizedDescription)"),
                status: .failed
            )
        }
    }

    private func performRemoteDelete(item: BrowserItem, request: DeleteRequest, recursively: Bool) {
        let clientBox = SendableRemoteClientBox(remoteClient)
        let itemName = request.itemName
        let remotePath = item.pathDescription
        let isDirectory = item.isDirectory
        beginRemoteActivity()
        remoteWorkQueue.async {
            let result: Result<Void, Error>
            do {
                try clientBox.client.deleteItem(
                    named: itemName,
                    at: remotePath,
                    isDirectory: isDirectory,
                    recursively: recursively
                )
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.endRemoteActivity()
                switch result {
                case .success:
                    self.reloadRemoteDirectoryAsync(selecting: nil)
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Deleted \(itemName) from Remote."),
                        status: .completed
                    )
                case .failure(let error):
                    self.transferFeedback = TransferFeedback(
                        message: String(localized: "Delete failed: \(error.localizedDescription)"),
                        status: .failed
                    )
                }
            }
        }
    }

    private func beginRemoteActivity() {
        remoteActivityCount += 1
    }

    private func endRemoteActivity() {
        remoteActivityCount = max(0, remoteActivityCount - 1)
    }

    private func setLocalDirectory(_ url: URL, securityScopeRoot: URL? = nil) {
        localDirectoryURL = url.standardizedFileURL

        if let securityScopeRoot {
            establishLocalDirectoryAccess(at: securityScopeRoot.standardizedFileURL)
            syncDefaultPlaces()
            return
        }

        guard let currentRoot = localSecurityScopeRootURL else { return }
        let currentRootPath = currentRoot.path(percentEncoded: false)
        let targetPath = localDirectoryURL.path(percentEncoded: false)
        if !targetPath.hasPrefix(currentRootPath) {
            stopLocalDirectoryAccess()
        }
        syncDefaultPlaces()
    }

    @discardableResult
    private func openLocalDirectory(_ url: URL, title: String? = nil) -> Bool {
        let standardizedURL = url.standardizedFileURL

        do {
            _ = try localFileBrowser.loadItems(in: standardizedURL)
            setLocalDirectory(standardizedURL)
            localErrorMessage = nil
            reloadDirectory(in: .local, selecting: nil)
            return true
        } catch {
            guard isLocalDirectoryAuthorizationError(error) else {
                setLocalDirectory(standardizedURL)
                localErrorMessage = error.localizedDescription
                reloadDirectory(in: .local, selecting: nil)
                return false
            }

            return requestLocalDirectoryAccess(for: standardizedURL, title: title)
        }
    }

    @discardableResult
    private func requestLocalDirectoryAccess(for url: URL, title: String? = nil) -> Bool {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Grant Folder Access")
        if let title, !title.isEmpty {
            panel.message = String(localized: "FilePier needs permission to open \(title). Select a folder to grant access.")
        } else {
            panel.message = String(localized: "FilePier needs permission to open this folder. Select a folder to grant access.")
        }
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            ? url
            : url.deletingLastPathComponent()

        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            localErrorMessage = String(localized: "Folder access was not granted. Choose Folder to authorize a local directory.")
            return false
        }

        setLocalDirectory(selectedURL, securityScopeRoot: selectedURL)
        localErrorMessage = nil
        reloadDirectory(in: .local, selecting: nil)
        return true
    }

    private func isLocalDirectoryAuthorizationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            let code = CocoaError.Code(rawValue: nsError.code)
            if code == .fileReadNoPermission || code == .fileWriteNoPermission {
                return true
            }
        }

        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == EACCES || nsError.code == EPERM
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isLocalDirectoryAuthorizationError(underlyingError)
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("permission") || message.contains("not permitted")
    }

    private func syncDefaultPlaces() {
        let favorites = places.filter(\.isFavorite)
        places = favorites + Self.defaultPlaces(currentLocalDirectory: localDirectoryURL)
    }

    private func saveFavoritePlaces(_ favorites: [PlaceItem]) throws {
        let records = favorites.compactMap { place -> FavoritePlaceRecord? in
            if case .localDirectory(let url) = place.destination {
                return FavoritePlaceRecord(
                    url: url,
                    customTitle: place.title == Self.defaultFavoriteTitle(for: url) ? nil : place.title
                )
            }
            return nil
        }
        try favoritePlaceStore.saveFavoritePlaces(records)
    }

    private func resetRemoteSession(showFeedback: Bool, displayHost: String? = nil) {
        remoteConnectionAttemptID = UUID()
        remoteSessionServerID = nil
        remoteClient = MockRemoteClient(
            localFileBrowser: localFileBrowser,
            displayHost: displayHost ?? selectedServer?.endpoint ?? "mock-sftp.local"
        )
        remoteLocation = remoteClient.makeInitialLocation(relativeTo: localDirectoryURL)
        remoteItems = []
        selectedRemoteItemID = nil
        remoteErrorMessage = nil
        remoteHomePath = nil
        remotePathDraft = ""
        remoteActivityCount = 0
        transferControls.removeAll()
        remoteSessionStatus = .idle
        if showFeedback {
            transferFeedback = TransferFeedback(
                message: String(localized: "Disconnected remote session."),
                status: .completed
            )
        }
    }

    private func persistWorkspacePreferences() {
        do {
            try workspacePreferenceStore.savePreferences(
                WorkspacePreferences(
                    showsInspector: showsInspector,
                    browserDensity: browserDensity,
                    maxConcurrentTransfers: maxConcurrentTransfers,
                    localBrowserSort: localBrowserSort,
                    remoteBrowserSort: remoteBrowserSort
                )
            )
        } catch {
            transferFeedback = TransferFeedback(
                message: String(localized: "Save workspace preferences failed: \(error.localizedDescription)"),
                status: .failed
            )
        }
    }

    private func establishLocalDirectoryAccess(at url: URL) {
        let standardizedURL = url.standardizedFileURL
        if localSecurityScopeRootURL == standardizedURL {
            return
        }

        stopLocalDirectoryAccess()
        guard standardizedURL.startAccessingSecurityScopedResource() else { return }
        localSecurityScopeRootURL = standardizedURL
    }

    private func stopLocalDirectoryAccess() {
        guard let localSecurityScopeRootURL else { return }
        localSecurityScopeRootURL.stopAccessingSecurityScopedResource()
        self.localSecurityScopeRootURL = nil
    }

    private func withLocalDirectoryAccess<T>(_ operation: () throws -> T) throws -> T {
        if let localSecurityScopeRootURL {
            return try withSecurityScopedAccess(to: localSecurityScopeRootURL, operation: operation)
        }
        return try operation()
    }
}

private final class SendableRemoteClientBox: @unchecked Sendable {
    let client: any RemoteClient

    init(_ client: any RemoteClient) {
        self.client = client
    }
}

private func withSecurityScopedAccess<T>(to url: URL, operation: () throws -> T) throws -> T {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
    return try operation()
}

private func stageUploadSource(at sourceURL: URL) throws -> URL {
    let fileManager = FileManager.default
    let stagingDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("FilePierUploadStaging", isDirectory: true)
    try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

    let stagedURL = stagingDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)

    try fileManager.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.copyItem(at: sourceURL, to: stagedURL)
    return stagedURL
}

private func resolvedByteCount(for url: URL) throws -> Int64 {
    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
    if resourceValues.isDirectory == true {
        return 0
    }
    if let fileSize = resourceValues.fileSize {
        return Int64(fileSize)
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let fileSize = attributes[.size] as? NSNumber {
        return fileSize.int64Value
    }

    throw NSError(
        domain: "FilePierWorkspaceState",
        code: CocoaError.fileReadUnknown.rawValue,
        userInfo: [NSLocalizedDescriptionKey: String(localized: "Unable to determine file size for \(url.lastPathComponent).")]
    )
}

private func transferProgressDetail(prefix: String, progress: TransferProgressSnapshot) -> String {
    guard let totalByteCount = progress.totalByteCount else {
        return prefix
    }

    let completed = ByteCountFormatter.string(fromByteCount: progress.completedByteCount, countStyle: .file)
    let total = ByteCountFormatter.string(fromByteCount: totalByteCount, countStyle: .file)
    return String(localized: "\(prefix) (\(completed) of \(total))")
}

private func transferBatchDetail(
    operation: String,
    successCount: Int,
    cancelledCount: Int,
    failedCount: Int
) -> String {
    var fragments: [String] = []
    if successCount > 0 {
        fragments.append(String(localized: "\(successCount) completed"))
    }
    if cancelledCount > 0 {
        fragments.append(String(localized: "\(cancelledCount) cancelled"))
    }
    if failedCount > 0 {
        fragments.append(String(localized: "\(failedCount) failed"))
    }
    if fragments.isEmpty {
        return String(localized: "\(operation) batch finished with no processed items.")
    }
    return String(localized: "\(operation) batch: ") + fragments.joined(separator: ", ")
}

private func isTransferCancellationError(_ error: Error) -> Bool {
    func containsCancellation(_ error: Error, visited: inout Set<String>) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        let visitKey = "\(nsError.domain)#\(nsError.code)#\(nsError.localizedDescription)"
        guard visited.insert(visitKey).inserted else { return false }

        if nsError.domain == "Swift.CancellationError" {
            return true
        }

        if String(reflecting: type(of: error)).contains("CancellationError") {
            return true
        }

        if nsError.localizedDescription.contains("CancellationError") {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           containsCancellation(underlying, visited: &visited) {
            return true
        }

        if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [NSError] {
            for nested in detailed where containsCancellation(nested, visited: &visited) {
                return true
            }
        }

        return false
    }

    var visited: Set<String> = []
    return containsCancellation(error, visited: &visited)
}

private func transferBatchProgressDetail(
    operation: String,
    destination: String,
    queuedCount: Int,
    successCount: Int,
    cancelledCount: Int,
    failedCount: Int
) -> String {
    var fragments = [String(localized: "\(queuedCount) queued")]
    if successCount > 0 {
        fragments.append(String(localized: "\(successCount) completed"))
    }
    if cancelledCount > 0 {
        fragments.append(String(localized: "\(cancelledCount) cancelled"))
    }
    if failedCount > 0 {
        fragments.append(String(localized: "\(failedCount) failed"))
    }
    return String(localized: "\(operation) queue to \(destination): ") + fragments.joined(separator: ", ")
}

private func transferBatchTitle(singleTitle: String?, itemCount: Int, itemLabel: String) -> String {
    if itemCount <= 1, let singleTitle {
        return singleTitle
    }
    return String(localized: "\(itemCount) \(itemLabel)")
}

private func remoteByteCount(
    named fileName: String,
    at location: RemoteLocation,
    using client: any RemoteClient,
    expectedMinimumByteCount: Int64? = nil
) throws -> Int64? {
    let attempts = 5

    for attempt in 0..<attempts {
        let byteCount = try client
            .loadItems(in: location)
            .first(where: { $0.name == fileName })?
            .byteCount

        if
            let expectedMinimumByteCount,
            expectedMinimumByteCount > 0,
            byteCount == 0,
            attempt < attempts - 1
        {
            Thread.sleep(forTimeInterval: 0.25)
            continue
        }

        return byteCount
    }

    return nil
}

extension FilePierWorkspaceState {
    static func hasSavedPassword(
        for server: ServerProfile?,
        credentialStore: any ServerCredentialStore
    ) -> Bool {
        guard let server else { return false }
        return ((try? credentialStore.password(for: server.id)) ?? "").isEmpty == false
    }

    static func loadInitialServers(savedServerStore: any SavedServerStore) -> [ServerProfile] {
        guard let savedServers = try? savedServerStore.loadServers(), !savedServers.isEmpty else {
            return sampleServers
        }
        return savedServers
    }

    static func loadInitialWorkspacePreferences(
        workspacePreferenceStore: any WorkspacePreferenceStore
    ) -> WorkspacePreferences {
        (try? workspacePreferenceStore.loadPreferences()) ?? .default
    }

    static func loadInitialSiteUsage(siteUsageStore: any SiteUsageStore) -> [UUID: SiteUsageRecord] {
        (try? siteUsageStore.loadUsage()) ?? [:]
    }

    static func initialPlaces(
        currentLocalDirectory: URL,
        favoritePlaceStore: any FavoritePlaceStore
    ) -> [PlaceItem] {
        let favoritePlaces = ((try? favoritePlaceStore.loadFavoritePlaces()) ?? [])
            .map(makeFavoritePlace)
        return favoritePlaces + defaultPlaces(currentLocalDirectory: currentLocalDirectory)
    }

    static func makeConnectionDraft(
        for server: ServerProfile?,
        credentialStore: any ServerCredentialStore
    ) -> ConnectionDraft {
        var draft = ConnectionDraft.from(server: server)
        if let server {
            draft.password = (try? credentialStore.password(for: server.id)) ?? ""
        }
        draft.clearsSavedPassword = false
        return draft
    }

    static let defaultRemoteSessionFactory: RemoteSessionFactory = { server, draft, localFileBrowser in
        switch server.connectionKind {
        case .sftp:
            let config = RemoteConnectionConfig(
                connectionKind: .sftp,
                host: draft.host,
                port: Int(draft.port) ?? server.port,
                username: draft.username,
                authenticationMode: draft.authenticationMode,
                privateKeyPath: draft.privateKeyPath.isEmpty ? nil : draft.privateKeyPath,
                privateKeyBookmarkData: draft.privateKeyBookmarkData,
                publicKeyPath: draft.publicKeyPath.isEmpty ? nil : draft.publicKeyPath,
                publicKeyBookmarkData: draft.publicKeyBookmarkData,
                password: draft.password.isEmpty ? nil : draft.password,
                addressPreference: draft.addressPreference,
                s3Region: nil
            )
            return RemoteSessionServices(
                client: LibraryBackedSFTPRemoteClient(config: config)
            )
        case .cloud:
            let config = RemoteConnectionConfig(
                connectionKind: .cloud,
                host: draft.host,
                port: Int(draft.port) ?? server.port,
                username: draft.username,
                authenticationMode: .password,
                privateKeyPath: nil,
                publicKeyPath: nil,
                password: draft.password.isEmpty ? nil : draft.password,
                addressPreference: draft.addressPreference,
                s3Region: {
                    let trimmed = draft.s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
            )
            return RemoteSessionServices(
                client: LibraryBackedS3RemoteClient(config: config)
            )
        case .webdav:
            return RemoteSessionServices(
                client: LibraryBackedWebDAVRemoteClient(
                    config: RemoteConnectionConfig(
                        connectionKind: .webdav,
                        host: draft.host,
                        port: Int(draft.port) ?? server.port,
                        username: draft.username,
                        authenticationMode: .password,
                        privateKeyPath: nil,
                        publicKeyPath: nil,
                        password: draft.password.isEmpty ? nil : draft.password,
                        addressPreference: draft.addressPreference,
                        s3Region: nil
                    )
                )
            )
        }
    }

    static let sampleServers: [ServerProfile] = [
        .init(name: "Production SFTP", endpoint: "app.example.com", port: 22, username: "deploy", connectionKind: .sftp, systemImage: "server.rack", accentName: "Orange"),
        .init(name: "Marketing WebDAV", endpoint: "dav.example.com", port: 443, username: "marketing", connectionKind: .webdav, systemImage: "network", accentName: "Green")
    ]

    static func makeFavoritePlace(from record: FavoritePlaceRecord) -> PlaceItem {
        let standardizedURL = record.url
        let path = standardizedURL.path(percentEncoded: false)
        let title = record.customTitle ?? defaultFavoriteTitle(for: standardizedURL)
        return PlaceItem(
            id: "favorite:\(path)",
            title: title,
            subtitle: path,
            systemImage: "star.fill",
            destination: .localDirectory(standardizedURL),
            isFavorite: true,
            allowsRemoval: true
        )
    }

    static func defaultFavoriteTitle(for url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let title = url.standardizedFileURL.lastPathComponent
        return title.isEmpty ? path : title
    }

    static func defaultPlaces(currentLocalDirectory: URL) -> [PlaceItem] {
        let fileManager = FileManager.default
        let homeDirectory = LocalUserDirectories.home(fileManager: fileManager)
        let desktopDirectory = LocalUserDirectories.desktop(fileManager: fileManager)
        let documentsDirectory = LocalUserDirectories.documents(fileManager: fileManager)
        let downloadsDirectory = LocalUserDirectories.downloads(fileManager: fileManager)

        let localDirectories: [(String, URL?, String, Bool)] = [
            (String(localized: "Current Folder"), currentLocalDirectory.standardizedFileURL, "folder.fill", false),
            (String(localized: "Home"), homeDirectory, "house.fill", false),
            (String(localized: "Desktop"), desktopDirectory, "macwindow", false),
            (String(localized: "Documents"), documentsDirectory, "doc.text.fill", false),
            (String(localized: "Downloads"), downloadsDirectory, "arrow.down.circle.fill", false)
        ]

        let placeDirectories: [PlaceItem] = localDirectories.compactMap { title, url, systemImage, isFavorite -> PlaceItem? in
            guard let url else { return nil }
            return PlaceItem(
                id: "place:\(title):\(url.path(percentEncoded: false))",
                title: title,
                subtitle: url.path(percentEncoded: false),
                systemImage: systemImage,
                destination: .localDirectory(url),
                isFavorite: isFavorite,
                allowsRemoval: false
            )
        }

        return placeDirectories + [
            PlaceItem(
                id: "workspace:transfers",
                title: String(localized: "Transfers"),
                subtitle: String(localized: "Recent activity"),
                systemImage: "arrow.left.arrow.right",
                destination: .transfers,
                isFavorite: false,
                allowsRemoval: false
            ),
            PlaceItem(
                id: "workspace:keys",
                title: String(localized: "Keys"),
                subtitle: String(localized: "SSH identities"),
                systemImage: "key.fill",
                destination: .keys,
                isFavorite: false,
                allowsRemoval: false
            )
        ]
    }

    private func configureNetworkMonitor() {
        networkMonitor?.setUpdateHandler { [weak self] reachable in
            Task { @MainActor [weak self] in
                self?.handleNetworkReachabilityChanged(reachable)
            }
        }
        networkMonitor?.start()
    }

    private func handleNetworkReachabilityChanged(_ reachable: Bool) {
        guard isNetworkReachable != reachable else { return }
        isNetworkReachable = reachable

        guard remoteSessionServerID != nil || remoteSessionStatus == .connecting || isConnectedStatus(remoteSessionStatus) else {
            return
        }

        if reachable {
            if remoteErrorMessage == String(localized: "Network connection lost. Check Wi-Fi or Ethernet and reconnect.") {
                remoteErrorMessage = nil
            }
            if case .failed(let message) = remoteSessionStatus, message == String(localized: "Network Offline") {
                remoteSessionStatus = .idle
            }
            transferFeedback = TransferFeedback(
                message: String(localized: "Network restored. Reconnect to continue browsing the remote site."),
                status: .completed
            )
        } else {
            remoteErrorMessage = String(localized: "Network connection lost. Check Wi-Fi or Ethernet and reconnect.")
            remoteSessionStatus = .failed(String(localized: "Network Offline"))
            transferFeedback = TransferFeedback(
                message: String(localized: "Network connection lost. Remote browsing is unavailable."),
                status: .failed
            )
        }
    }

    private func sortItems(_ items: [BrowserItem], using option: BrowserSortOption) -> [BrowserItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            let comparison = comparisonValue(lhs, rhs, field: option.field)
            if comparison == 0 {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return option.ascending ? comparison < 0 : comparison > 0
        }
    }

    private func comparisonValue(_ lhs: BrowserItem, _ rhs: BrowserItem, field: BrowserSortField) -> Int {
        switch field {
        case .name:
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending:
                return -1
            case .orderedDescending:
                return 1
            case .orderedSame:
                return 0
            }
        case .modified:
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (lhsDate?, rhsDate?):
                if lhsDate < rhsDate { return -1 }
                if lhsDate > rhsDate { return 1 }
                return 0
            case (nil, nil):
                return 0
            case (nil, _?):
                return 1
            case (_?, nil):
                return -1
            }
        case .size:
            switch (lhs.byteCount, rhs.byteCount) {
            case let (lhsSize?, rhsSize?):
                if lhsSize < rhsSize { return -1 }
                if lhsSize > rhsSize { return 1 }
                return 0
            case (nil, nil):
                return 0
            case (nil, _?):
                return 1
            case (_?, nil):
                return -1
            }
        }
    }

    private func isConnectedStatus(_ status: RemoteSessionStatus) -> Bool {
        if case .connected = status {
            return true
        }
        return false
    }

}
