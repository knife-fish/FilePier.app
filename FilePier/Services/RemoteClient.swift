import Foundation

struct TransferProgressSnapshot: Sendable, Equatable {
    let completedByteCount: Int64
    let totalByteCount: Int64?

    var fractionCompleted: Double {
        guard let totalByteCount else { return 0 }
        guard totalByteCount > 0 else { return 1 }
        return min(max(Double(completedByteCount) / Double(totalByteCount), 0), 1)
    }
}

struct RemoteDirectorySnapshot {
    let location: RemoteLocation
    let items: [BrowserItem]
    let homePath: String?
}

struct RemoteUploadResult {
    let remoteItemID: String
    let destinationName: String
    let renamedForConflict: Bool
}

struct RemoteMutationResult {
    let remoteItemID: String
    let destinationName: String
}

protocol RemoteClient {
    func makeInitialLocation(relativeTo localDirectoryURL: URL) -> RemoteLocation
    func makeLocation(for directoryURL: URL) -> RemoteLocation
    func parentLocation(of location: RemoteLocation) -> RemoteLocation?
    func location(for item: BrowserItem, from currentLocation: RemoteLocation) -> RemoteLocation?
    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot
    func destinationDirectoryURL(for location: RemoteLocation) -> URL?
    func uploadItem(
        at localURL: URL,
        to remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> RemoteUploadResult
    func downloadItem(
        named name: String,
        at remotePath: String,
        toDirectory localDirectoryURL: URL,
        localFileTransfer: LocalFileTransferService,
        conflictPolicy: TransferConflictPolicy,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> LocalFileTransferResult
    func createDirectory(named proposedName: String, in remoteLocation: RemoteLocation) throws -> RemoteMutationResult
    func renameItem(named originalName: String, at remotePath: String, to proposedName: String) throws -> RemoteMutationResult
    func deleteItem(named name: String, at remotePath: String, isDirectory: Bool, recursively: Bool) throws
}

extension RemoteClient {
    func loadItems(in location: RemoteLocation) throws -> [BrowserItem] {
        try loadDirectorySnapshot(in: location).items
    }

    func createDirectory(
        named proposedName: String,
        in remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy
    ) throws -> RemoteMutationResult {
        switch conflictPolicy {
        case .rename:
            return try createDirectory(named: proposedName, in: remoteLocation)
        case .overwrite:
            if let existingItem = try loadItems(in: remoteLocation).first(where: { $0.name == proposedName }) {
                try deleteItem(
                    named: existingItem.name,
                    at: existingItem.pathDescription,
                    isDirectory: existingItem.isDirectory,
                    recursively: true
                )
            }
            return try createDirectory(named: proposedName, in: remoteLocation)
        }
    }
}

struct RemoteSessionServices {
    let client: any RemoteClient
}
