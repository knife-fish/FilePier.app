import Foundation

protocol TransferQueueStore {
    func loadTransfers() throws -> [SavedTransfer]
    func saveTransfers(_ transfers: [SavedTransfer]) throws
}

/// Credentials stay in Keychain. This identity prevents a restored task from
/// running against a different account, including an edited saved site.
struct TransferServerIdentity: Codable, Equatable {
    let name: String
    let endpoint: String
    let port: Int
    let username: String
    let connectionKind: ConnectionKind
    let s3Region: String?

    init(_ server: ServerProfile) {
        name = server.name
        endpoint = server.endpoint
        port = server.port
        username = server.username
        connectionKind = server.connectionKind
        s3Region = server.s3Region
    }

    func matches(_ server: ServerProfile) -> Bool {
        endpoint == server.endpoint && port == server.port && username == server.username
            && connectionKind == server.connectionKind
            && (connectionKind != .cloud || s3Region == server.s3Region)
    }
}

struct SavedTransfer: Codable, Identifiable {
    let id: UUID
    let title: String
    let server: TransferServerIdentity
    let localAccess: SavedLocalDirectory
    let descriptor: TransferRetryDescriptor
    let conflictPolicy: TransferConflictPolicy
    let isDirectory: Bool
    var createdAt: Date = Date()
    var progress: Double = 0
    // Once created, retain the actual folder destination (including a renamed
    // duplicate) while enumerating its children.
    var preparedRemoteDirectory: RemoteLocation?
    var preparedLocalDirectory: URL?
}

struct JSONTransferQueueStore: TransferQueueStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("FilePier", isDirectory: true)
            .appendingPathComponent("TransferQueue.json")
    }

    func loadTransfers() throws -> [SavedTransfer] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SavedTransfer].self, from: Data(contentsOf: fileURL))
    }

    func saveTransfers(_ transfers: [SavedTransfer]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(transfers).write(to: fileURL, options: .atomic)
    }
}

final class InMemoryTransferQueueStore: TransferQueueStore {
    var transfers: [SavedTransfer] = []
    func loadTransfers() throws -> [SavedTransfer] { transfers }
    func saveTransfers(_ transfers: [SavedTransfer]) throws { self.transfers = transfers }
}
