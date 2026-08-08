import Foundation

protocol SavedServerStore {
    func loadServers() throws -> [ServerProfile]
    func saveServers(_ servers: [ServerProfile]) throws
}

struct JSONSavedServerStore: SavedServerStore {
    let fileURL: URL

    init(fileURL: URL = JSONSavedServerStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func loadServers() throws -> [ServerProfile] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode([StoredServerProfile].self, from: data).map(\.serverProfile)
    }

    func saveServers(_ servers: [ServerProfile]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(servers.map(StoredServerProfile.init))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("FilePier", isDirectory: true)
            .appendingPathComponent("SavedServers.json", isDirectory: false)
    }
}

private struct StoredServerProfile: Codable {
    let id: UUID
    let name: String
    let endpoint: String
    let port: Int
    let username: String
    let connectionKind: ConnectionKind
    let authenticationMode: ConnectionAuthenticationMode?
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

    nonisolated init(_ serverProfile: ServerProfile) {
        self.id = serverProfile.id
        self.name = serverProfile.name
        self.endpoint = serverProfile.endpoint
        self.port = serverProfile.port
        self.username = serverProfile.username
        self.connectionKind = serverProfile.connectionKind
        self.authenticationMode = serverProfile.authenticationMode
        self.privateKeyPath = serverProfile.privateKeyPath
        self.privateKeyBookmarkData = serverProfile.privateKeyBookmarkData
        self.publicKeyPath = serverProfile.publicKeyPath
        self.publicKeyBookmarkData = serverProfile.publicKeyBookmarkData
        self.addressPreference = serverProfile.addressPreference
        self.s3Region = serverProfile.s3Region
        self.defaultLocalDirectoryPath = serverProfile.defaultLocalDirectoryPath
        self.defaultRemotePath = serverProfile.defaultRemotePath
        self.systemImage = serverProfile.systemImage
        self.accentName = serverProfile.accentName
    }

    var serverProfile: ServerProfile {
        let privateKeyPath = privateKeyPath.map {
            sshKeyPathPreservingHomeSSHLink(
                for: URL(fileURLWithPath: expandingCurrentUserHomeDirectory(in: $0))
            )
        }
        let publicKeyPath = publicKeyPath.map {
            sshKeyPathPreservingHomeSSHLink(
                for: URL(fileURLWithPath: expandingCurrentUserHomeDirectory(in: $0))
            )
        }

        return ServerProfile(
            id: id,
            name: name,
            endpoint: endpoint,
            port: port,
            username: username,
            connectionKind: connectionKind,
            authenticationMode: authenticationMode ?? .password,
            privateKeyPath: privateKeyPath,
            privateKeyBookmarkData: privateKeyBookmarkData,
            publicKeyPath: publicKeyPath,
            publicKeyBookmarkData: publicKeyBookmarkData,
            addressPreference: addressPreference,
            s3Region: s3Region,
            defaultLocalDirectoryPath: defaultLocalDirectoryPath,
            defaultRemotePath: defaultRemotePath,
            systemImage: systemImage,
            accentName: accentName
        )
    }
}
