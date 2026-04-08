import Foundation

struct RemoteLocation: Hashable {
    let id: String
    let path: String
    let remotePath: String
    let directoryURL: URL?
}

struct RemoteConnectionConfig: Hashable {
    let connectionKind: ConnectionKind
    let host: String
    let port: Int
    let username: String
    let authenticationMode: ConnectionAuthenticationMode
    let privateKeyPath: String?
    let privateKeyBookmarkData: Data?
    let publicKeyPath: String?
    let publicKeyBookmarkData: Data?
    let password: String?
    let addressPreference: ConnectionAddressPreference
    let s3Region: String?

    init(
        connectionKind: ConnectionKind,
        host: String,
        port: Int,
        username: String,
        authenticationMode: ConnectionAuthenticationMode,
        privateKeyPath: String?,
        privateKeyBookmarkData: Data? = nil,
        publicKeyPath: String?,
        publicKeyBookmarkData: Data? = nil,
        password: String?,
        addressPreference: ConnectionAddressPreference,
        s3Region: String?
    ) {
        self.connectionKind = connectionKind
        self.host = host
        self.port = port
        self.username = username
        self.authenticationMode = authenticationMode
        self.privateKeyPath = privateKeyPath
        self.privateKeyBookmarkData = privateKeyBookmarkData
        self.publicKeyPath = publicKeyPath
        self.publicKeyBookmarkData = publicKeyBookmarkData
        self.password = password
        self.addressPreference = addressPreference
        self.s3Region = s3Region
    }
}

struct MockRemoteClient: RemoteClient {
    private let localFileBrowser: LocalFileBrowserService
    private let displayHost: String

    init(localFileBrowser: LocalFileBrowserService = LocalFileBrowserService(), displayHost: String = "mock-sftp.local") {
        self.localFileBrowser = localFileBrowser
        self.displayHost = displayHost
    }

    func makeInitialLocation(relativeTo localDirectoryURL: URL) -> RemoteLocation {
        let secondaryDirectory = localFileBrowser.makeSecondaryDirectoryURL(relativeTo: localDirectoryURL)
        return makeLocation(for: secondaryDirectory)
    }

    func makeLocation(for directoryURL: URL) -> RemoteLocation {
        let standardizedURL = directoryURL.standardizedFileURL
        return RemoteLocation(
            id: standardizedURL.path(percentEncoded: false),
            path: "sftp://\(displayHost)\(standardizedURL.path(percentEncoded: false))",
            remotePath: standardizedURL.path(percentEncoded: false),
            directoryURL: standardizedURL
        )
    }

    func parentLocation(of location: RemoteLocation) -> RemoteLocation? {
        guard let directoryURL = location.directoryURL else { return nil }
        let standardizedURL = directoryURL.standardizedFileURL
        let parentURL = standardizedURL.deletingLastPathComponent()
        guard parentURL.path != standardizedURL.path else { return nil }
        return makeLocation(for: parentURL)
    }

    func location(for item: BrowserItem, from currentLocation: RemoteLocation) -> RemoteLocation? {
        guard item.isDirectory, let directoryURL = item.url else { return nil }
        return makeLocation(for: directoryURL)
    }

    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        guard let directoryURL = location.directoryURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let normalizedLocation = makeLocation(for: directoryURL)
        return RemoteDirectorySnapshot(
            location: normalizedLocation,
            items: try localFileBrowser.loadItems(in: directoryURL),
            homePath: normalizedLocation.remotePath
        )
    }

    func destinationDirectoryURL(for location: RemoteLocation) -> URL? {
        location.directoryURL
    }

    func uploadItem(
        at localURL: URL,
        to remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> RemoteUploadResult {
        guard let destinationDirectoryURL = remoteLocation.directoryURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destinationURL = try LocalFileTransferService().destinationURL(
            forProposedName: localURL.lastPathComponent,
            in: destinationDirectoryURL,
            conflictPolicy: conflictPolicy
        )
        if conflictPolicy == .overwrite, FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try LocalFileTransferService().deleteItem(at: destinationURL)
        }
        try copyFileWithProgress(from: localURL, to: destinationURL, progress: progress, isCancelled: isCancelled)
        return RemoteUploadResult(
            remoteItemID: destinationURL.path(percentEncoded: false),
            destinationName: destinationURL.lastPathComponent,
            renamedForConflict: destinationURL.lastPathComponent != localURL.lastPathComponent
        )
    }

    func downloadItem(
        named name: String,
        at remotePath: String,
        toDirectory localDirectoryURL: URL,
        localFileTransfer: LocalFileTransferService,
        conflictPolicy: TransferConflictPolicy,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> LocalFileTransferResult {
        let sourceURL = URL(fileURLWithPath: remotePath)
        let destinationURL = try localFileTransfer.destinationURL(
            forProposedName: name,
            in: localDirectoryURL,
            conflictPolicy: conflictPolicy
        )
        if conflictPolicy == .overwrite, FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try localFileTransfer.deleteItem(at: destinationURL)
        }
        try copyFileWithProgress(from: sourceURL, to: destinationURL, progress: progress, isCancelled: isCancelled)
        return LocalFileTransferResult(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            renamedForConflict: destinationURL.lastPathComponent != name
        )
    }

    func createDirectory(named proposedName: String, in remoteLocation: RemoteLocation) throws -> RemoteMutationResult {
        guard let directoryURL = remoteLocation.directoryURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let createdURL = try LocalFileTransferService().createDirectory(named: proposedName, in: directoryURL)
        return RemoteMutationResult(
            remoteItemID: createdURL.path(percentEncoded: false),
            destinationName: createdURL.lastPathComponent
        )
    }

    func renameItem(named originalName: String, at remotePath: String, to proposedName: String) throws -> RemoteMutationResult {
        let sourceURL = URL(fileURLWithPath: remotePath)
        let renamedURL = try LocalFileTransferService().renameItem(at: sourceURL, toName: proposedName)
        return RemoteMutationResult(
            remoteItemID: renamedURL.path(percentEncoded: false),
            destinationName: renamedURL.lastPathComponent
        )
    }

    func deleteItem(named name: String, at remotePath: String, isDirectory: Bool, recursively: Bool) throws {
        try LocalFileTransferService().deleteItem(
            at: URL(fileURLWithPath: remotePath),
            recursively: recursively
        )
    }

    private func copyFileWithProgress(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        let fileManager = FileManager.default
        let totalByteCount = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        fileManager.createFile(atPath: destinationURL.path(percentEncoded: false), contents: nil)

        let inputHandle = try FileHandle(forReadingFrom: sourceURL)
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
        }

        let chunkSize = 64 * 1024
        var completedByteCount: Int64 = 0
        progress?(.init(completedByteCount: 0, totalByteCount: totalByteCount))

        while true {
            if isCancelled?() == true {
                try? FileManager.default.removeItem(at: destinationURL)
                throw CancellationError()
            }
            let data = try inputHandle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try outputHandle.write(contentsOf: data)
            completedByteCount += Int64(data.count)
            progress?(.init(completedByteCount: completedByteCount, totalByteCount: totalByteCount))
        }

        if completedByteCount == 0 {
            progress?(.init(completedByteCount: 0, totalByteCount: totalByteCount ?? 0))
        }
    }
}
