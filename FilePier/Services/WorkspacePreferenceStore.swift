import Foundation

protocol WorkspacePreferenceStore {
    func loadPreferences() throws -> WorkspacePreferences
    func savePreferences(_ preferences: WorkspacePreferences) throws
}

struct WorkspacePreferences: Codable, Equatable {
    var showsInspector: Bool
    var browserDensity: BrowserDensityMode
    var maxConcurrentTransfers: Int
    var localBrowserSort: BrowserSortOption
    var remoteBrowserSort: BrowserSortOption
    var lastLocalDirectory: SavedLocalDirectory?
    var lastConnectedServerID: UUID?
    var serverWorkspaces: [UUID: ServerWorkspacePreferences] = [:]

    static let `default` = WorkspacePreferences(
        showsInspector: true,
        browserDensity: .comfortable,
        maxConcurrentTransfers: 2,
        localBrowserSort: .default,
        remoteBrowserSort: .default
    )

    init(
        showsInspector: Bool,
        browserDensity: BrowserDensityMode,
        maxConcurrentTransfers: Int,
        localBrowserSort: BrowserSortOption,
        remoteBrowserSort: BrowserSortOption
    ) {
        self.showsInspector = showsInspector
        self.browserDensity = browserDensity
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.localBrowserSort = localBrowserSort
        self.remoteBrowserSort = remoteBrowserSort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsInspector = try container.decodeIfPresent(Bool.self, forKey: .showsInspector) ?? Self.default.showsInspector
        browserDensity = try container.decodeIfPresent(BrowserDensityMode.self, forKey: .browserDensity) ?? Self.default.browserDensity
        maxConcurrentTransfers = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentTransfers) ?? Self.default.maxConcurrentTransfers
        localBrowserSort = try container.decodeIfPresent(BrowserSortOption.self, forKey: .localBrowserSort) ?? Self.default.localBrowserSort
        remoteBrowserSort = try container.decodeIfPresent(BrowserSortOption.self, forKey: .remoteBrowserSort) ?? Self.default.remoteBrowserSort
        lastLocalDirectory = try container.decodeIfPresent(SavedLocalDirectory.self, forKey: .lastLocalDirectory)
        lastConnectedServerID = try container.decodeIfPresent(UUID.self, forKey: .lastConnectedServerID)
        serverWorkspaces = try container.decodeIfPresent([UUID: ServerWorkspacePreferences].self, forKey: .serverWorkspaces) ?? [:]
    }
}

struct ServerWorkspacePreferences: Codable, Equatable {
    var localDirectory: SavedLocalDirectory
    var remotePath: String
    var localBrowserSort: BrowserSortOption
    var remoteBrowserSort: BrowserSortOption
}

/// Keep the granted ancestor as well as the browsed path so navigating into a
/// child folder does not lose the sandbox permission on the next launch.
struct SavedLocalDirectory: Codable, Equatable {
    var path: String
    var accessRootPath: String
    var bookmarkData: Data?

    init(url: URL, accessRootURL: URL? = nil) {
        path = url.path(percentEncoded: false)
        let root = accessRootURL ?? url
        accessRootPath = root.path(percentEncoded: false)
        bookmarkData = try? root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    var url: URL { URL(fileURLWithPath: path) }

    var accessRootURL: URL {
        if let bookmarkData {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return resolved
            }
        }
        return URL(fileURLWithPath: accessRootPath)
    }
}

final class InMemoryWorkspacePreferenceStore: WorkspacePreferenceStore {
    var preferences: WorkspacePreferences = .default
    func loadPreferences() throws -> WorkspacePreferences { preferences }
    func savePreferences(_ preferences: WorkspacePreferences) throws { self.preferences = preferences }
}

struct JSONWorkspacePreferenceStore: WorkspacePreferenceStore {
    let fileURL: URL

    init(fileURL: URL = JSONWorkspacePreferenceStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func loadPreferences() throws -> WorkspacePreferences {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return .default
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(WorkspacePreferences.self, from: data)
    }

    func savePreferences(_ preferences: WorkspacePreferences) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("FilePier", isDirectory: true)
            .appendingPathComponent("WorkspacePreferences.json", isDirectory: false)
    }
}
