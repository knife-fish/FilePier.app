import Citadel
import Crypto
import Darwin
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Security

enum RemoteClientError: LocalizedError {
    case requestFailed(details: String)
    case operationTimedOut(operation: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let details):
            return details
        case .operationTimedOut(let operation, let seconds):
            return "\(operation) timed out after \(Int(seconds)) seconds."
        }
    }
}

private func readSecurityScopedTextFile(at selectedURL: URL, bookmarkData: Data? = nil) throws -> String {
    guard let bookmarkData else {
        return try String(contentsOf: selectedURL, encoding: .utf8)
    }

    var isBookmarkStale = false
    let scopeURL = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isBookmarkStale
    )
    let didStartAccess = scopeURL.startAccessingSecurityScopedResource()
    guard didStartAccess else {
        throw RemoteClientError.requestFailed(
            details: "FilePier no longer has permission to read the selected SSH key. Choose the key file again to grant access."
        )
    }
    defer {
        scopeURL.stopAccessingSecurityScopedResource()
    }

    // Security-scoped bookmarks resolve a symbolic-link selection to the
    // authorized target URL. Reading that URL is required by App Sandbox;
    // `selectedURL` is retained separately for display and persistence.
    return try String(contentsOf: scopeURL, encoding: .utf8)
}

struct LibraryBackedSFTPRemoteClient: RemoteClient {
    private let config: RemoteConnectionConfig
    private let session: CitadelSFTPSession

    init(config: RemoteConnectionConfig) {
        self.config = config
        self.session = CitadelSFTPSession(config: config)
    }

    func makeInitialLocation(relativeTo localDirectoryURL: URL) -> RemoteLocation {
        RemoteLocation(
            id: ".",
            path: "sftp://\(config.normalizedHost)/~",
            remotePath: ".",
            directoryURL: nil
        )
    }

    func makeLocation(for directoryURL: URL) -> RemoteLocation {
        makeRemoteLocation(path: directoryURL.path(percentEncoded: false))
    }

    func parentLocation(of location: RemoteLocation) -> RemoteLocation? {
        guard location.remotePath != "/" else { return nil }
        let parent = (location.remotePath as NSString).deletingLastPathComponent
        return makeRemoteLocation(path: parent.isEmpty ? "/" : parent)
    }

    func location(for item: BrowserItem, from currentLocation: RemoteLocation) -> RemoteLocation? {
        guard item.isDirectory else { return nil }
        return makeRemoteLocation(path: item.pathDescription)
    }

    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        let snapshot = try session.loadDirectorySnapshot(in: location)
        let sortedItems = snapshot.items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return RemoteDirectorySnapshot(
            location: makeRemoteLocation(path: snapshot.location.remotePath),
            items: sortedItems,
            homePath: snapshot.homePath
        )
    }

    func destinationDirectoryURL(for location: RemoteLocation) -> URL? {
        nil
    }

    func uploadItem(
        at localURL: URL,
        to remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> RemoteUploadResult {
        let resourceValues = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if resourceValues.isDirectory == true {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let destinationName = try resolvedRemoteName(
            proposedName: localURL.lastPathComponent,
            in: remoteLocation,
            conflictPolicy: conflictPolicy
        )
        let destinationPath = join(remotePath: remoteLocation.remotePath, name: destinationName)
        if conflictPolicy == .overwrite,
           let existingItem = try loadItems(in: remoteLocation).first(where: { $0.name == destinationName }) {
            guard !existingItem.isDirectory else {
                throw CocoaError(.fileWriteFileExists)
            }
            try session.deleteItem(at: existingItem.pathDescription, isDirectory: false, recursively: false)
        }
        try session.uploadItem(at: localURL, toPath: destinationPath, progress: progress, isCancelled: isCancelled)
        return RemoteUploadResult(
            remoteItemID: destinationPath,
            destinationName: destinationName,
            renamedForConflict: destinationName != localURL.lastPathComponent
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
        let destinationURL = try localFileTransfer.destinationURL(
            forProposedName: name,
            in: localDirectoryURL,
            conflictPolicy: conflictPolicy
        )
        if conflictPolicy == .overwrite, FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try localFileTransfer.deleteItem(at: destinationURL)
        }
        try session.downloadItem(at: remotePath, to: destinationURL, progress: progress, isCancelled: isCancelled)
        return LocalFileTransferResult(
            sourceURL: URL(fileURLWithPath: remotePath),
            destinationURL: destinationURL,
            renamedForConflict: destinationURL.lastPathComponent != name
        )
    }

    func createDirectory(named proposedName: String, in remoteLocation: RemoteLocation) throws -> RemoteMutationResult {
        let sanitizedName = try validateRemoteName(proposedName)
        let destinationName = try makeUniqueRemoteName(proposedName: sanitizedName, in: remoteLocation)
        let destinationPath = join(remotePath: remoteLocation.remotePath, name: destinationName)
        try session.createDirectory(at: destinationPath)
        return RemoteMutationResult(
            remoteItemID: destinationPath,
            destinationName: destinationName
        )
    }

    func renameItem(named originalName: String, at remotePath: String, to proposedName: String) throws -> RemoteMutationResult {
        let sanitizedName = try validateRemoteName(proposedName)
        let parentPath = parentPath(for: remotePath)
        let destinationPath = join(remotePath: parentPath, name: sanitizedName)
        guard destinationPath != remotePath else {
            return RemoteMutationResult(remoteItemID: remotePath, destinationName: sanitizedName)
        }

        let siblingItems = try loadItems(in: makeRemoteLocation(path: parentPath))
        guard !siblingItems.contains(where: { $0.name == sanitizedName && $0.pathDescription != remotePath }) else {
            throw CocoaError(.fileWriteFileExists)
        }

        try session.renameItem(at: remotePath, to: destinationPath)
        return RemoteMutationResult(
            remoteItemID: destinationPath,
            destinationName: sanitizedName
        )
    }

    func deleteItem(named name: String, at remotePath: String, isDirectory: Bool, recursively: Bool) throws {
        try session.deleteItem(at: remotePath, isDirectory: isDirectory, recursively: recursively)
    }

    private func makeRemoteLocation(path: String) -> RemoteLocation {
        let normalizedPath = normalizedRemotePath(path)
        return RemoteLocation(
            id: normalizedPath,
            path: "sftp://\(config.normalizedHost)\(normalizedPath)",
            remotePath: normalizedPath,
            directoryURL: nil
        )
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func join(remotePath: String, name: String) -> String {
        if remotePath == "/" {
            return "/\(name)"
        }
        return "\(remotePath)/\(name)"
    }

    private func parentPath(for remotePath: String) -> String {
        let parent = (remotePath as NSString).deletingLastPathComponent
        if parent.isEmpty {
            return "/"
        }
        return normalizedRemotePath(parent)
    }

    private func validateRemoteName(_ proposedName: String) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return trimmed
    }

    private func makeUniqueRemoteName(proposedName: String, in remoteLocation: RemoteLocation) throws -> String {
        let sanitizedName = try validateRemoteName(proposedName)
        let siblingNames = Set(try loadItems(in: remoteLocation).map(\.name))
        guard siblingNames.contains(sanitizedName) else {
            return sanitizedName
        }

        let pathExtension = URL(fileURLWithPath: sanitizedName).pathExtension
        let baseName = pathExtension.isEmpty
            ? sanitizedName
            : String(sanitizedName.dropLast(pathExtension.count + 1))

        var candidateIndex = 2
        while true {
            let candidateBase = "\(baseName) \(candidateIndex)"
            let candidate = pathExtension.isEmpty
                ? candidateBase
                : "\(candidateBase).\(pathExtension)"
            if !siblingNames.contains(candidate) {
                return candidate
            }
            candidateIndex += 1
        }
    }

    private func resolvedRemoteName(
        proposedName: String,
        in remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy
    ) throws -> String {
        switch conflictPolicy {
        case .rename:
            return try makeUniqueRemoteName(proposedName: proposedName, in: remoteLocation)
        case .overwrite:
            return try validateRemoteName(proposedName)
        }
    }
}

struct LibraryBackedS3RemoteClient: RemoteClient {
    private let config: RemoteConnectionConfig
    private let transport: S3HTTPSession

    init(
        config: RemoteConnectionConfig,
        transport: S3HTTPSession? = nil
    ) {
        self.config = config
        self.transport = transport ?? S3HTTPSession(config: config)
    }

    func makeInitialLocation(relativeTo localDirectoryURL: URL) -> RemoteLocation {
        makeRemoteLocation(path: "/")
    }

    func makeLocation(for directoryURL: URL) -> RemoteLocation {
        makeRemoteLocation(path: directoryURL.path(percentEncoded: false))
    }

    func parentLocation(of location: RemoteLocation) -> RemoteLocation? {
        guard location.remotePath != "/" else { return nil }
        let parent = (location.remotePath as NSString).deletingLastPathComponent
        return makeRemoteLocation(path: parent.isEmpty ? "/" : parent)
    }

    func location(for item: BrowserItem, from currentLocation: RemoteLocation) -> RemoteLocation? {
        guard item.isDirectory else { return nil }
        return makeRemoteLocation(path: item.pathDescription)
    }

    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        let snapshot = try transport.loadDirectorySnapshot(in: location)
        let sortedItems = snapshot.items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return RemoteDirectorySnapshot(
            location: makeRemoteLocation(path: snapshot.location.remotePath),
            items: sortedItems,
            homePath: snapshot.homePath
        )
    }

    func destinationDirectoryURL(for location: RemoteLocation) -> URL? {
        nil
    }

    func uploadItem(
        at localURL: URL,
        to remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> RemoteUploadResult {
        let resourceValues = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if resourceValues.isDirectory == true {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let destinationName = try resolvedRemoteName(
            proposedName: localURL.lastPathComponent,
            in: remoteLocation,
            conflictPolicy: conflictPolicy
        )
        let destinationPath = join(remotePath: remoteLocation.remotePath, name: destinationName)
        let object = try transport.resolveObjectReference(for: destinationPath)
        try transport.uploadObject(
            at: localURL,
            bucket: object.bucket,
            key: object.key,
            progress: progress,
            isCancelled: isCancelled
        )
        return RemoteUploadResult(
            remoteItemID: destinationPath,
            destinationName: destinationName,
            renamedForConflict: destinationName != localURL.lastPathComponent
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
        let destinationURL = try localFileTransfer.destinationURL(
            forProposedName: name,
            in: localDirectoryURL,
            conflictPolicy: conflictPolicy
        )
        if conflictPolicy == .overwrite, FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try localFileTransfer.deleteItem(at: destinationURL)
        }

        let object = try transport.resolveObjectReference(for: remotePath)
        try transport.downloadObject(
            bucket: object.bucket,
            key: object.key,
            to: destinationURL,
            progress: progress,
            isCancelled: isCancelled
        )
        return LocalFileTransferResult(
            sourceURL: URL(fileURLWithPath: remotePath),
            destinationURL: destinationURL,
            renamedForConflict: destinationURL.lastPathComponent != name
        )
    }

    func createDirectory(named proposedName: String, in remoteLocation: RemoteLocation) throws -> RemoteMutationResult {
        let sanitizedName = try validateRemoteName(proposedName)
        let destinationName = try makeUniqueRemoteName(proposedName: sanitizedName, in: remoteLocation)
        let destinationPath = join(remotePath: remoteLocation.remotePath, name: destinationName)
        let directory = try transport.resolveDirectoryReference(for: destinationPath, allowRootBucket: false)
        try transport.createDirectory(bucket: directory.bucket, prefix: directory.prefix)
        return RemoteMutationResult(
            remoteItemID: destinationPath,
            destinationName: destinationName
        )
    }

    func renameItem(named originalName: String, at remotePath: String, to proposedName: String) throws -> RemoteMutationResult {
        let sanitizedName = try validateRemoteName(proposedName)
        let parentPath = parentPath(for: remotePath)
        let destinationPath = join(remotePath: parentPath, name: sanitizedName)
        guard destinationPath != remotePath else {
            return RemoteMutationResult(remoteItemID: remotePath, destinationName: sanitizedName)
        }

        let siblingItems = try loadItems(in: makeRemoteLocation(path: parentPath))
        guard !siblingItems.contains(where: { $0.name == sanitizedName && $0.pathDescription != remotePath }) else {
            throw CocoaError(.fileWriteFileExists)
        }

        if remotePath.hasSuffix("/") {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let sourceDirectory = try transport.resolveDirectoryReferenceIfPossible(for: remotePath)
        if let sourceDirectory, sourceDirectory.prefix != nil {
            let destinationDirectory = try transport.resolveDirectoryReference(for: destinationPath, allowRootBucket: false)
            try transport.renamePrefix(
                bucket: sourceDirectory.bucket,
                fromPrefix: sourceDirectory.prefix,
                toPrefix: destinationDirectory.prefix
            )
        } else {
            let sourceObject = try transport.resolveObjectReference(for: remotePath)
            let destinationObject = try transport.resolveObjectReference(for: destinationPath)
            try transport.renameObject(
                bucket: sourceObject.bucket,
                fromKey: sourceObject.key,
                toKey: destinationObject.key
            )
        }

        return RemoteMutationResult(
            remoteItemID: destinationPath,
            destinationName: sanitizedName
        )
    }

    func deleteItem(named name: String, at remotePath: String, isDirectory: Bool, recursively: Bool) throws {
        if isDirectory {
            let directory = try transport.resolveDirectoryReference(for: remotePath, allowRootBucket: true)
            try transport.deletePrefix(bucket: directory.bucket, prefix: directory.prefix)
        } else {
            let object = try transport.resolveObjectReference(for: remotePath)
            try transport.deleteObject(bucket: object.bucket, key: object.key)
        }
    }

    private func makeRemoteLocation(path: String) -> RemoteLocation {
        let normalizedPath = normalizedRemotePath(path)
        return RemoteLocation(
            id: normalizedPath,
            path: "s3://\(config.normalizedHost)\(normalizedPath)",
            remotePath: normalizedPath,
            directoryURL: nil
        )
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func join(remotePath: String, name: String) -> String {
        if remotePath == "/" {
            return "/\(name)"
        }
        return "\(remotePath)/\(name)"
    }

    private func parentPath(for remotePath: String) -> String {
        let parent = (remotePath as NSString).deletingLastPathComponent
        if parent.isEmpty {
            return "/"
        }
        return normalizedRemotePath(parent)
    }

    private func validateRemoteName(_ proposedName: String) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return trimmed
    }

    private func makeUniqueRemoteName(proposedName: String, in remoteLocation: RemoteLocation) throws -> String {
        let sanitizedName = try validateRemoteName(proposedName)
        let siblingNames = Set(try loadItems(in: remoteLocation).map(\.name))
        guard siblingNames.contains(sanitizedName) else {
            return sanitizedName
        }

        let pathExtension = URL(fileURLWithPath: sanitizedName).pathExtension
        let baseName = pathExtension.isEmpty
            ? sanitizedName
            : String(sanitizedName.dropLast(pathExtension.count + 1))

        var candidateIndex = 2
        while true {
            let candidateBase = "\(baseName) \(candidateIndex)"
            let candidate = pathExtension.isEmpty
                ? candidateBase
                : "\(candidateBase).\(pathExtension)"
            if !siblingNames.contains(candidate) {
                return candidate
            }
            candidateIndex += 1
        }
    }

    private func resolvedRemoteName(
        proposedName: String,
        in remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy
    ) throws -> String {
        switch conflictPolicy {
        case .rename:
            return try makeUniqueRemoteName(proposedName: proposedName, in: remoteLocation)
        case .overwrite:
            return try validateRemoteName(proposedName)
        }
    }

}

struct LibraryBackedWebDAVRemoteClient: RemoteClient {
    private let config: RemoteConnectionConfig
    private let transport: WebDAVHTTPSession

    init(
        config: RemoteConnectionConfig,
        transport: WebDAVHTTPSession? = nil
    ) {
        self.config = config
        self.transport = transport ?? WebDAVHTTPSession(config: config)
    }

    func makeInitialLocation(relativeTo localDirectoryURL: URL) -> RemoteLocation {
        makeRemoteLocation(path: "/")
    }

    func makeLocation(for directoryURL: URL) -> RemoteLocation {
        makeRemoteLocation(path: directoryURL.path(percentEncoded: false))
    }

    func parentLocation(of location: RemoteLocation) -> RemoteLocation? {
        guard location.remotePath != "/" else { return nil }
        let parent = (location.remotePath as NSString).deletingLastPathComponent
        return makeRemoteLocation(path: parent.isEmpty ? "/" : parent)
    }

    func location(for item: BrowserItem, from currentLocation: RemoteLocation) -> RemoteLocation? {
        guard item.isDirectory else { return nil }
        return makeRemoteLocation(path: item.pathDescription)
    }

    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        let snapshot = try transport.loadDirectorySnapshot(in: location)
        let sortedItems = snapshot.items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return RemoteDirectorySnapshot(
            location: makeRemoteLocation(path: snapshot.location.remotePath),
            items: sortedItems,
            homePath: snapshot.homePath
        )
    }

    func destinationDirectoryURL(for location: RemoteLocation) -> URL? {
        nil
    }

    func uploadItem(
        at localURL: URL,
        to remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> RemoteUploadResult {
        let resourceValues = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if resourceValues.isDirectory == true {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let destinationName = try resolvedRemoteName(
            proposedName: localURL.lastPathComponent,
            in: remoteLocation,
            conflictPolicy: conflictPolicy
        )
        let destinationPath = join(remotePath: remoteLocation.remotePath, name: destinationName)
        try transport.uploadItem(
            at: localURL,
            toRemotePath: destinationPath,
            progress: progress,
            isCancelled: isCancelled
        )
        return RemoteUploadResult(
            remoteItemID: destinationPath,
            destinationName: destinationName,
            renamedForConflict: destinationName != localURL.lastPathComponent
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
        let destinationURL = try localFileTransfer.destinationURL(
            forProposedName: name,
            in: localDirectoryURL,
            conflictPolicy: conflictPolicy
        )
        if conflictPolicy == .overwrite, FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try localFileTransfer.deleteItem(at: destinationURL)
        }

        try transport.downloadItem(
            atRemotePath: remotePath,
            to: destinationURL,
            progress: progress,
            isCancelled: isCancelled
        )
        return LocalFileTransferResult(
            sourceURL: URL(fileURLWithPath: remotePath),
            destinationURL: destinationURL,
            renamedForConflict: destinationURL.lastPathComponent != name
        )
    }

    func createDirectory(named proposedName: String, in remoteLocation: RemoteLocation) throws -> RemoteMutationResult {
        let sanitizedName = try validateRemoteName(proposedName)
        let destinationName = try makeUniqueRemoteName(proposedName: sanitizedName, in: remoteLocation)
        let destinationPath = join(remotePath: remoteLocation.remotePath, name: destinationName)
        try transport.createDirectory(atRemotePath: destinationPath)
        return RemoteMutationResult(
            remoteItemID: destinationPath,
            destinationName: destinationName
        )
    }

    func renameItem(named originalName: String, at remotePath: String, to proposedName: String) throws -> RemoteMutationResult {
        let sanitizedName = try validateRemoteName(proposedName)
        let parentPath = parentPath(for: remotePath)
        let destinationPath = join(remotePath: parentPath, name: sanitizedName)
        guard destinationPath != remotePath else {
            return RemoteMutationResult(remoteItemID: remotePath, destinationName: sanitizedName)
        }

        let siblingItems = try loadItems(in: makeRemoteLocation(path: parentPath))
        guard !siblingItems.contains(where: { $0.name == sanitizedName && $0.pathDescription != remotePath }) else {
            throw CocoaError(.fileWriteFileExists)
        }

        try transport.renameItem(atRemotePath: remotePath, toRemotePath: destinationPath)
        return RemoteMutationResult(
            remoteItemID: destinationPath,
            destinationName: sanitizedName
        )
    }

    func deleteItem(named name: String, at remotePath: String, isDirectory: Bool, recursively: Bool) throws {
        try transport.deleteItem(atRemotePath: remotePath)
    }

    private func makeRemoteLocation(path: String) -> RemoteLocation {
        let normalizedPath = normalizedRemotePath(path)
        return RemoteLocation(
            id: normalizedPath,
            path: "dav://\(config.normalizedHost)\(normalizedPath)",
            remotePath: normalizedPath,
            directoryURL: nil
        )
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func join(remotePath: String, name: String) -> String {
        if remotePath == "/" {
            return "/\(name)"
        }
        return "\(remotePath)/\(name)"
    }

    private func parentPath(for remotePath: String) -> String {
        let parent = (remotePath as NSString).deletingLastPathComponent
        if parent.isEmpty {
            return "/"
        }
        return normalizedRemotePath(parent)
    }

    private func validateRemoteName(_ proposedName: String) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return trimmed
    }

    private func makeUniqueRemoteName(proposedName: String, in remoteLocation: RemoteLocation) throws -> String {
        let sanitizedName = try validateRemoteName(proposedName)
        let siblingNames = Set(try loadItems(in: remoteLocation).map(\.name))
        guard siblingNames.contains(sanitizedName) else {
            return sanitizedName
        }

        let pathExtension = URL(fileURLWithPath: sanitizedName).pathExtension
        let baseName = pathExtension.isEmpty
            ? sanitizedName
            : String(sanitizedName.dropLast(pathExtension.count + 1))

        var candidateIndex = 2
        while true {
            let candidateBase = "\(baseName) \(candidateIndex)"
            let candidate = pathExtension.isEmpty
                ? candidateBase
                : "\(candidateBase).\(pathExtension)"
            if !siblingNames.contains(candidate) {
                return candidate
            }
            candidateIndex += 1
        }
    }

    private func resolvedRemoteName(
        proposedName: String,
        in remoteLocation: RemoteLocation,
        conflictPolicy: TransferConflictPolicy
    ) throws -> String {
        switch conflictPolicy {
        case .rename:
            return try makeUniqueRemoteName(proposedName: proposedName, in: remoteLocation)
        case .overwrite:
            return try validateRemoteName(proposedName)
        }
    }
}

final class S3HTTPSession: NSObject {
    private static let requestTimeout: TimeInterval = 30
    private static let fileTransferTimeout: TimeInterval = 600
    private static let defaultRegion = "us-east-1"

    private let config: RemoteConnectionConfig
    private let endpointURL: URL
    private let endpointResolutionError: Error?
    private let urlSessionConfiguration: URLSessionConfiguration
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var rootMode: S3RootMode
    private var signingRegion: String

    init(
        config: RemoteConnectionConfig,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.config = config
        do {
            self.endpointURL = try config.resolvedHTTPEndpointURL()
            self.endpointResolutionError = nil
        } catch {
            self.endpointURL = URL(string: "http://invalid.local")!
            self.endpointResolutionError = error
        }
        self.urlSessionConfiguration = urlSessionConfiguration
        self.now = now
        self.rootMode = Self.initialRootMode(for: self.endpointURL)
        self.signingRegion = config.s3Region?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? config.s3Region!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.defaultRegion
        super.init()
    }

    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        _ = try validatedEndpointURL()
        let normalizedLocation = makeRemoteLocation(path: location.remotePath)
        if normalizedLocation.remotePath == "/" {
            switch try discoverRootListing() {
            case .service(let buckets):
                return RemoteDirectorySnapshot(
                    location: normalizedLocation,
                    items: buckets.map(makeBucketBrowserItem).sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    },
                    homePath: "/"
                )
            case .bucket(let bucket, let response):
                let items = makeBrowserItems(
                    bucket: bucket,
                    currentPrefix: nil,
                    response: response,
                    usesBucketScopedPaths: true
                )
                return RemoteDirectorySnapshot(
                    location: normalizedLocation,
                    items: items,
                    homePath: "/"
                )
            }
        }

        let directory = try resolveDirectoryReference(for: normalizedLocation.remotePath, allowRootBucket: true)
        let response = try listObjects(bucket: directory.bucket, prefix: directory.prefix, delimiter: "/")
        let items = makeBrowserItems(
            bucket: directory.bucket,
            currentPrefix: directory.prefix,
            response: response,
            usesBucketScopedPaths: currentRootMode.isBucketScoped
        )
        return RemoteDirectorySnapshot(
            location: normalizedLocation,
            items: items,
            homePath: "/"
        )
    }

    func uploadObject(
        at localURL: URL,
        bucket: String,
        key: String,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        _ = try validatedEndpointURL()
        let payloadHash = try sha256Hex(forFileAt: localURL)
        let contentLength = try localFileByteCount(for: localURL)
        progress?(.init(completedByteCount: 0, totalByteCount: contentLength))
        var request = try signedRequest(
            method: "PUT",
            path: objectPath(bucket: bucket, key: key),
            queryItems: [],
            headers: [
                "content-length": String(contentLength)
            ],
            payloadHash: payloadHash,
            date: now()
        )

        let delegate = BlockingURLSessionDelegate(
            progress: progress,
            destinationURL: nil
        )
        let session = URLSession(configuration: urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        request.httpMethod = "PUT"
        let task = session.uploadTask(with: request, fromFile: localURL)
        try runTask(
            task,
            delegate: delegate,
            timeout: Self.fileTransferTimeout,
            operationDescription: "Uploading \(localURL.lastPathComponent)",
            isCancelled: isCancelled
        )
        progress?(.init(completedByteCount: contentLength, totalByteCount: contentLength))
    }

    func downloadObject(
        bucket: String,
        key: String,
        to destinationURL: URL,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        _ = try validatedEndpointURL()
        let request = try signedRequest(
            method: "GET",
            path: objectPath(bucket: bucket, key: key),
            queryItems: [],
            headers: [:],
            payloadHash: Self.emptyPayloadSHA256,
            date: now()
        )

        let delegate = BlockingURLSessionDelegate(
            progress: progress,
            destinationURL: destinationURL
        )
        let session = URLSession(configuration: urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.downloadTask(with: request)
        try runTask(
            task,
            delegate: delegate,
            timeout: Self.fileTransferTimeout,
            operationDescription: "Downloading \(destinationURL.lastPathComponent)",
            isCancelled: isCancelled
        )
    }

    func createDirectory(bucket: String, prefix: String?) throws {
        _ = try validatedEndpointURL()
        guard let prefix else {
            throw RemoteClientError.requestFailed(details: "S3 buckets are managed outside this app; create a folder inside an existing bucket.")
        }

        let key = prefix.hasSuffix("/") ? prefix : prefix + "/"
        _ = try executeDataRequest(
            method: "PUT",
            path: objectPath(bucket: bucket, key: key),
            queryItems: [],
            headers: [:],
            payloadHash: Self.emptyPayloadSHA256,
            timeout: Self.requestTimeout
        )
    }

    func renameObject(bucket: String, fromKey: String, toKey: String) throws {
        _ = try validatedEndpointURL()
        try copyObject(bucket: bucket, fromKey: fromKey, toKey: toKey)
        try deleteObject(bucket: bucket, key: fromKey)
    }

    func renamePrefix(bucket: String, fromPrefix: String?, toPrefix: String?) throws {
        _ = try validatedEndpointURL()
        let sourcePrefix = fromPrefix ?? ""
        let destinationPrefix = toPrefix ?? ""
        let objects = try listObjectsRecursively(bucket: bucket, prefix: sourcePrefix)
        for object in objects where !object.key.isEmpty {
            let suffix = object.key.dropFirst(sourcePrefix.count)
            try copyObject(bucket: bucket, fromKey: object.key, toKey: destinationPrefix + suffix)
        }
        try deletePrefix(bucket: bucket, prefix: fromPrefix)
    }

    func deleteObject(bucket: String, key: String) throws {
        _ = try validatedEndpointURL()
        _ = try executeDataRequest(
            method: "DELETE",
            path: objectPath(bucket: bucket, key: key),
            queryItems: [],
            headers: [:],
            payloadHash: Self.emptyPayloadSHA256,
            timeout: Self.requestTimeout
        )
    }

    func deletePrefix(bucket: String, prefix: String?) throws {
        _ = try validatedEndpointURL()
        guard let prefix else {
            throw RemoteClientError.requestFailed(details: "Bucket deletion is not supported from this app.")
        }

        let objects = try listObjectsRecursively(bucket: bucket, prefix: prefix)
        for object in objects where !object.key.isEmpty {
            try deleteObject(bucket: bucket, key: object.key)
        }
    }

    func resolveDirectoryReference(
        for remotePath: String,
        allowRootBucket: Bool
    ) throws -> (bucket: String, prefix: String?) {
        _ = try validatedEndpointURL()
        let normalizedPath = normalizedRemotePath(remotePath)
        switch currentRootMode {
        case .bucket(let bucket):
            if normalizedPath == "/" {
                if allowRootBucket {
                    return (bucket, nil)
                }
                throw RemoteClientError.requestFailed(details: "Choose a folder inside the bucket before creating a subfolder.")
            }
            let prefix = normalizedPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return (bucket, prefix.isEmpty ? nil : prefix + "/")
        case .service:
            guard normalizedPath != "/" else {
                throw RemoteClientError.requestFailed(details: "Choose a bucket before creating a folder.")
            }

            let components = normalizedPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard let bucket = components.first, !bucket.isEmpty else {
                throw RemoteClientError.requestFailed(details: "The S3 path is missing a bucket name.")
            }

            let remainder = Array(components.dropFirst())
            guard !remainder.isEmpty else {
                return (bucket, nil)
            }
            return (bucket, remainder.joined(separator: "/") + "/")
        }
    }

    func resolveDirectoryReferenceIfPossible(for remotePath: String) throws -> (bucket: String, prefix: String?)? {
        _ = try validatedEndpointURL()
        let normalizedPath = normalizedRemotePath(remotePath)
        guard normalizedPath != "/" else { return nil }

        switch currentRootMode {
        case .bucket(let bucket):
            let prefix = normalizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !prefix.isEmpty else { return (bucket, nil) }
            let leaf = (prefix as NSString).lastPathComponent
            if leaf.contains(".") {
                return nil
            }
            return (bucket, prefix + "/")
        case .service:
            let components = normalizedPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard let bucket = components.first, !bucket.isEmpty else {
                return nil
            }

            let remainder = Array(components.dropFirst())
            if remainder.isEmpty {
                return (bucket, nil)
            }

            let leaf = remainder.last ?? ""
            if leaf.contains(".") {
                return nil
            }
            return (bucket, remainder.joined(separator: "/") + "/")
        }
    }

    func resolveObjectReference(for remotePath: String) throws -> (bucket: String, key: String) {
        _ = try validatedEndpointURL()
        let normalizedPath = normalizedRemotePath(remotePath)
        switch currentRootMode {
        case .bucket(let bucket):
            let key = normalizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !key.isEmpty else {
                throw RemoteClientError.requestFailed(details: "The S3 object key is empty for the current bucket endpoint.")
            }
            return (bucket, key)
        case .service:
            let components = normalizedPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard components.count >= 2 else {
                throw RemoteClientError.requestFailed(details: "The S3 object path must include both bucket and object key.")
            }

            let bucket = components[0]
            let key = components.dropFirst().joined(separator: "/")
            guard !bucket.isEmpty, !key.isEmpty else {
                throw RemoteClientError.requestFailed(details: "The S3 object path is invalid.")
            }
            return (bucket, key)
        }
    }

    private func listBuckets() throws -> [S3Bucket] {
        _ = try validatedEndpointURL()
        let data = try executeDataRequest(
            method: "GET",
            path: "/",
            queryItems: [],
            headers: [:],
            payloadHash: Self.emptyPayloadSHA256,
            timeout: Self.requestTimeout
        ).data
        return try S3ListBucketsXMLParser.parse(data: data)
    }

    private func discoverRootListing() throws -> S3RootListing {
        _ = try validatedEndpointURL()
        let data = try executeDataRequest(
            method: "GET",
            path: "/",
            queryItems: [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "delimiter", value: "/")],
            headers: [:],
            payloadHash: Self.emptyPayloadSHA256,
            timeout: Self.requestTimeout
        ).data

        let document = try XMLNodeDocument.parse(data: data)
        switch document.root.name {
        case "ListBucketResult":
            let response = try S3ListObjectsXMLParser.parse(data: data)
            let bucket = document.firstValue(named: "Name") ?? bucketNameFromEndpoint
            guard let bucket, !bucket.isEmpty else {
                throw RemoteClientError.requestFailed(details: "Connected to a bucket endpoint, but the bucket name could not be determined.")
            }
            setRootMode(.bucket(bucket))
            return .bucket(bucket: bucket, response: response)
        case "ListAllMyBucketsResult":
            let buckets = try S3ListBucketsXMLParser.parse(data: data)
            setRootMode(.service)
            return .service(buckets)
        default:
            let buckets = try listBuckets()
            setRootMode(.service)
            return .service(buckets)
        }
    }

    private func listObjects(bucket: String, prefix: String?, delimiter: String?) throws -> S3ListObjectsResponse {
        _ = try validatedEndpointURL()
        var queryItems = [URLQueryItem(name: "list-type", value: "2")]
        if let prefix {
            queryItems.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let delimiter {
            queryItems.append(URLQueryItem(name: "delimiter", value: delimiter))
        }

        let data = try executeDataRequest(
            method: "GET",
            path: requestPath(bucket: bucket),
            queryItems: queryItems,
            headers: [:],
            payloadHash: Self.emptyPayloadSHA256,
            timeout: Self.requestTimeout
        ).data
        return try S3ListObjectsXMLParser.parse(data: data)
    }

    private func listObjectsRecursively(bucket: String, prefix: String?) throws -> [S3ObjectEntry] {
        _ = try validatedEndpointURL()
        var objects: [S3ObjectEntry] = []
        var continuationToken: String?

        repeat {
            var queryItems = [URLQueryItem(name: "list-type", value: "2")]
            if let prefix {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: continuationToken))
            }

            let data = try executeDataRequest(
                method: "GET",
                path: requestPath(bucket: bucket),
                queryItems: queryItems,
                headers: [:],
                payloadHash: Self.emptyPayloadSHA256,
                timeout: Self.requestTimeout
            ).data
            let response = try S3ListObjectsXMLParser.parse(data: data)
            objects.append(contentsOf: response.objects)
            continuationToken = response.isTruncated ? response.nextContinuationToken : nil
        } while continuationToken != nil

        return objects
    }

    private func copyObject(bucket: String, fromKey: String, toKey: String) throws {
        _ = try validatedEndpointURL()
        _ = try executeDataRequest(
            method: "PUT",
            path: objectPath(bucket: bucket, key: toKey),
            queryItems: [],
            headers: [
                "x-amz-copy-source": copySource(bucket: bucket, key: fromKey)
            ],
            payloadHash: Self.emptyPayloadSHA256,
            timeout: Self.requestTimeout
        )
    }

    private func executeDataRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        payloadHash: String,
        timeout: TimeInterval
    ) throws -> (data: Data, response: HTTPURLResponse) {
        _ = try validatedEndpointURL()
        let request = try signedRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            headers: headers,
            payloadHash: payloadHash,
            date: now()
        )
        let delegate = BlockingURLSessionDelegate(progress: nil, destinationURL: nil)
        let session = URLSession(configuration: urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(with: request)
        return try runTask(
            task,
            delegate: delegate,
            timeout: timeout,
            operationDescription: "\(method) \(path)",
            isCancelled: nil
        )
    }

    @discardableResult
    private func runTask(
        _ task: URLSessionTask,
        delegate: BlockingURLSessionDelegate,
        timeout: TimeInterval,
        operationDescription: String,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> (data: Data, response: HTTPURLResponse) {
        task.resume()

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isCancelled?() == true {
                task.cancel()
                throw CancellationError()
            }

            if delegate.completed {
                break
            }

            if Date() >= deadline {
                task.cancel()
                throw RemoteClientError.operationTimedOut(operation: operationDescription, seconds: timeout)
            }

            _ = delegate.completionSemaphore.wait(timeout: .now() + 0.1)
        }

        if let error = delegate.error {
            if error is CancellationError {
                throw error
            }
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw RemoteClientError.requestFailed(details: error.localizedDescription)
        }

        if let downloadError = delegate.downloadMoveError {
            throw downloadError
        }

        guard let response = delegate.response as? HTTPURLResponse else {
            throw RemoteClientError.requestFailed(details: "The S3 server returned an invalid HTTP response.")
        }

        guard (200...299).contains(response.statusCode) else {
            let bodyText = String(data: delegate.receivedData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let details = bodyText?.isEmpty == false
                ? bodyText!
                : HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw RemoteClientError.requestFailed(details: "S3 request failed (\(response.statusCode)): \(details)")
        }

        return (delegate.receivedData, response)
    }

    private func signedRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        payloadHash: String,
        date: Date
    ) throws -> URLRequest {
        let endpointURL = try validatedEndpointURL()
        guard !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteClientError.requestFailed(details: "The Access Key field is empty.")
        }
        guard let secret = config.password, !secret.isEmpty else {
            throw RemoteClientError.requestFailed(details: "The Secret Key field is empty.")
        }

        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = endpointURL.path + encodedPath(path)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw RemoteClientError.requestFailed(details: "Failed to build the S3 request URL.")
        }

        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)
        let hostHeader = signedHostHeader(for: endpointURL)

        var signedHeaders = headers.reduce(into: [String: String]()) { partialResult, pair in
            partialResult[pair.key.lowercased()] = pair.value
        }
        signedHeaders["host"] = hostHeader
        signedHeaders["x-amz-content-sha256"] = payloadHash
        signedHeaders["x-amz-date"] = amzDate

        let authorization = try S3RequestSigner.sign(
            method: method,
            url: url,
            headers: signedHeaders,
            payloadHash: payloadHash,
            accessKey: config.username,
            secretKey: secret,
            region: currentSigningRegion,
            dateStamp: dateStamp,
            amzDate: amzDate
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.fileTransferTimeout
        for (name, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func validatedEndpointURL() throws -> URL {
        if let endpointResolutionError {
            throw endpointResolutionError
        }
        return endpointURL
    }

    private func makeRemoteLocation(path: String) -> RemoteLocation {
        let normalizedPath = normalizedRemotePath(path)
        return RemoteLocation(
            id: normalizedPath,
            path: "s3://\(config.normalizedHost)\(normalizedPath)",
            remotePath: normalizedPath,
            directoryURL: nil
        )
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func makeBucketBrowserItem(_ bucket: S3Bucket) -> BrowserItem {
        let path = "/\(bucket.name)"
        return BrowserItem(
            id: path,
            name: bucket.name,
            kind: .folder,
            byteCount: nil,
            modifiedAt: bucket.createdAt,
            sizeDescription: "--",
            modifiedDescription: modifiedDescription(for: bucket.createdAt),
            pathDescription: path,
            url: nil
        )
    }

    private func makeBrowserItems(
        bucket: String,
        currentPrefix: String?,
        response: S3ListObjectsResponse,
        usesBucketScopedPaths: Bool
    ) -> [BrowserItem] {
        let normalizedPrefix = currentPrefix ?? ""
        let prefixItems = response.commonPrefixes.compactMap { prefix -> BrowserItem? in
            let relativePrefix = prefix.hasPrefix(normalizedPrefix)
                ? String(prefix.dropFirst(normalizedPrefix.count))
                : prefix
            let trimmedPrefix = relativePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmedPrefix.isEmpty else { return nil }
            let path = displayDirectoryPath(
                bucket: bucket,
                prefix: normalizedPrefix + trimmedPrefix,
                usesBucketScopedPaths: usesBucketScopedPaths
            )
            return BrowserItem(
                id: path,
                name: trimmedPrefix,
                kind: .folder,
                byteCount: nil,
                modifiedAt: nil,
                sizeDescription: "--",
                modifiedDescription: "--",
                pathDescription: path,
                url: nil
            )
        }

        let objectItems = response.objects.compactMap { object -> BrowserItem? in
            if object.key == normalizedPrefix {
                return nil
            }

            let relativeKey = object.key.hasPrefix(normalizedPrefix)
                ? String(object.key.dropFirst(normalizedPrefix.count))
                : object.key
            guard !relativeKey.isEmpty, !relativeKey.contains("/") else {
                return nil
            }

            let path = displayObjectPath(
                bucket: bucket,
                key: object.key,
                usesBucketScopedPaths: usesBucketScopedPaths
            )
            return BrowserItem(
                id: path,
                name: relativeKey,
                kind: fileKind(for: relativeKey, isDirectory: false),
                byteCount: object.size,
                modifiedAt: object.lastModified,
                sizeDescription: sizeDescription(object.size),
                modifiedDescription: modifiedDescription(for: object.lastModified),
                pathDescription: path,
                url: nil
            )
        }

        return prefixItems + objectItems
    }

    private func requestPath(bucket: String) -> String {
        switch currentRootMode {
        case .bucket:
            return "/"
        case .service:
            return "/\(bucket)"
        }
    }

    private func objectPath(bucket: String, key: String) -> String {
        switch currentRootMode {
        case .bucket:
            return "/\(key)"
        case .service:
            return "/\(bucket)/\(key)"
        }
    }

    private func copySource(bucket: String, key: String) -> String {
        switch currentRootMode {
        case .bucket:
            return "/" + encodePathComponent(key)
        case .service:
            return "/" + [bucket, key]
                .map { encodePathComponent($0) }
                .joined(separator: "/")
        }
    }

    private func displayDirectoryPath(bucket: String, prefix: String, usesBucketScopedPaths: Bool) -> String {
        let normalizedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if usesBucketScopedPaths {
            return normalizedPrefix.isEmpty ? "/" : "/\(normalizedPrefix)"
        }
        return normalizedPrefix.isEmpty ? "/\(bucket)" : "/\(bucket)/\(normalizedPrefix)"
    }

    private func displayObjectPath(bucket: String, key: String, usesBucketScopedPaths: Bool) -> String {
        let normalizedKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if usesBucketScopedPaths {
            return "/\(normalizedKey)"
        }
        return "/\(bucket)/\(normalizedKey)"
    }

    private func signedHostHeader(for endpointURL: URL) -> String {
        guard let host = endpointURL.host else {
            return config.normalizedHost
        }
        if let port = endpointURL.port, port != 80, port != 443 {
            return "\(host):\(port)"
        }
        return host
    }

    private func encodedPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.map { encodePathComponent(String($0)) }.joined(separator: "/")
    }

    private func encodePathComponent(_ component: String) -> String {
        S3RequestSigner.uriEncode(component, encodeSlash: false)
    }

    private var currentRootMode: S3RootMode {
        lock.lock()
        defer { lock.unlock() }
        return rootMode
    }

    private var currentSigningRegion: String {
        lock.lock()
        defer { lock.unlock() }
        return signingRegion
    }

    private func setRootMode(_ mode: S3RootMode) {
        lock.lock()
        rootMode = mode
        lock.unlock()
    }

    private var bucketNameFromEndpoint: String? {
        if case .bucket(let bucket) = currentRootMode {
            return bucket
        }
        let components = endpointURL.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return components.first
    }

    private func setSigningRegion(_ region: String) {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        signingRegion = trimmed
        lock.unlock()
    }

    private func fileKind(for name: String, isDirectory: Bool) -> FileKind {
        if isDirectory {
            return .folder
        }

        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg":
            return .image
        case "zip", "tar", "gz", "tgz", "rar", "7z", "xz":
            return .archive
        case "swift", "js", "ts", "json", "sh", "py", "rb", "go", "rs", "yml", "yaml", "toml":
            return .code
        default:
            return .document
        }
    }

    private func sizeDescription(_ byteCount: Int64?) -> String {
        guard let byteCount else { return "--" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func modifiedDescription(for date: Date?) -> String {
        guard let date else { return "--" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        if Calendar.current.isDateInToday(date) {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            timeFormatter.dateStyle = .none
            return "\(String(localized: "Today")), \(timeFormatter.string(from: date))"
        }

        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }

        if abs(date.timeIntervalSinceNow) < 7 * 24 * 60 * 60 {
            return formatter.localizedString(for: date, relativeTo: Date()).capitalized
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }

    private static let emptyPayloadSHA256 = SHA256.hash(data: Data()).hexDigest

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func initialRootMode(for endpointURL: URL) -> S3RootMode {
        let components = endpointURL.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if let bucket = components.first, !bucket.isEmpty {
            return .bucket(bucket)
        }
        return .service
    }
}

final class WebDAVHTTPSession: NSObject {
    private static let requestTimeout: TimeInterval = 30
    private static let fileTransferTimeout: TimeInterval = 600

    private let config: RemoteConnectionConfig
    private let endpointURL: URL
    private let endpointResolutionError: Error?
    private let urlSessionConfiguration: URLSessionConfiguration

    init(
        config: RemoteConnectionConfig,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.config = config
        do {
            self.endpointURL = try config.resolvedWebDAVEndpointURL()
            self.endpointResolutionError = nil
        } catch {
            self.endpointURL = URL(string: "http://invalid.local")!
            self.endpointResolutionError = error
        }
        self.urlSessionConfiguration = urlSessionConfiguration
        super.init()
    }

    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        _ = try validatedEndpointURL()
        let normalizedLocation = makeRemoteLocation(path: location.remotePath)
        let targetURL = try resourceURL(forRemotePath: normalizedLocation.remotePath, isDirectoryHint: true)
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getlastmodified/>
          </d:prop>
        </d:propfind>
        """
        let result = try executeDataRequest(
            method: "PROPFIND",
            url: targetURL,
            headers: [
                "Depth": "1",
                "Content-Type": "application/xml; charset=utf-8"
            ],
            bodyData: Data(body.utf8),
            timeout: Self.requestTimeout,
            acceptedStatusCodes: [200, 207]
        )

        let responseItems = try WebDAVPROPFINDXMLParser.parse(
            data: result.data,
            endpointURL: endpointURL,
            requestedRemotePath: normalizedLocation.remotePath
        )

        return RemoteDirectorySnapshot(
            location: normalizedLocation,
            items: responseItems,
            homePath: "/"
        )
    }

    func uploadItem(
        at localURL: URL,
        toRemotePath remotePath: String,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        _ = try validatedEndpointURL()
        let targetURL = try resourceURL(forRemotePath: remotePath, isDirectoryHint: false)
        let contentLength = try localFileByteCount(for: localURL)
        progress?(.init(completedByteCount: 0, totalByteCount: contentLength))

        var request = try authorizedRequest(url: targetURL, method: "PUT")
        request.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")

        let delegate = BlockingURLSessionDelegate(progress: progress, destinationURL: nil)
        let session = URLSession(configuration: urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.uploadTask(with: request, fromFile: localURL)
        _ = try runTask(
            task,
            delegate: delegate,
            timeout: Self.fileTransferTimeout,
            operationDescription: "Uploading \(localURL.lastPathComponent)",
            isCancelled: isCancelled,
            acceptedStatusCodes: [200, 201, 204]
        )
        progress?(.init(completedByteCount: contentLength, totalByteCount: contentLength))
    }

    func downloadItem(
        atRemotePath remotePath: String,
        to destinationURL: URL,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        _ = try validatedEndpointURL()
        let targetURL = try resourceURL(forRemotePath: remotePath, isDirectoryHint: false)
        let request = try authorizedRequest(url: targetURL, method: "GET")

        let delegate = BlockingURLSessionDelegate(progress: progress, destinationURL: destinationURL)
        let session = URLSession(configuration: urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.downloadTask(with: request)
        _ = try runTask(
            task,
            delegate: delegate,
            timeout: Self.fileTransferTimeout,
            operationDescription: "Downloading \(destinationURL.lastPathComponent)",
            isCancelled: isCancelled,
            acceptedStatusCodes: [200]
        )
    }

    func createDirectory(atRemotePath remotePath: String) throws {
        _ = try validatedEndpointURL()
        let targetURL = try resourceURL(forRemotePath: remotePath, isDirectoryHint: true)
        _ = try executeDataRequest(
            method: "MKCOL",
            url: targetURL,
            headers: [:],
            bodyData: nil,
            timeout: Self.requestTimeout,
            acceptedStatusCodes: [201, 405]
        )
    }

    func renameItem(atRemotePath remotePath: String, toRemotePath destinationPath: String) throws {
        _ = try validatedEndpointURL()
        let sourceURL = try resourceURL(forRemotePath: remotePath, isDirectoryHint: nil)
        let destinationURL = try resourceURL(forRemotePath: destinationPath, isDirectoryHint: nil)
        _ = try executeDataRequest(
            method: "MOVE",
            url: sourceURL,
            headers: [
                "Destination": destinationURL.absoluteString,
                "Overwrite": "F"
            ],
            bodyData: nil,
            timeout: Self.requestTimeout,
            acceptedStatusCodes: [201, 204]
        )
    }

    func deleteItem(atRemotePath remotePath: String) throws {
        _ = try validatedEndpointURL()
        let targetURL = try resourceURL(forRemotePath: remotePath, isDirectoryHint: nil)
        _ = try executeDataRequest(
            method: "DELETE",
            url: targetURL,
            headers: [:],
            bodyData: nil,
            timeout: Self.requestTimeout,
            acceptedStatusCodes: [200, 204]
        )
    }

    private func executeDataRequest(
        method: String,
        url: URL,
        headers: [String: String],
        bodyData: Data?,
        timeout: TimeInterval,
        acceptedStatusCodes: Set<Int>
    ) throws -> (data: Data, response: HTTPURLResponse) {
        _ = try validatedEndpointURL()
        let request = try authorizedRequest(url: url, method: method, headers: headers, bodyData: bodyData)
        let delegate = BlockingURLSessionDelegate(progress: nil, destinationURL: nil)
        let session = URLSession(configuration: urlSessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(with: request)
        return try runTask(
            task,
            delegate: delegate,
            timeout: timeout,
            operationDescription: "\(method) \(url.path(percentEncoded: false))",
            isCancelled: nil,
            acceptedStatusCodes: acceptedStatusCodes
        )
    }

    @discardableResult
    private func runTask(
        _ task: URLSessionTask,
        delegate: BlockingURLSessionDelegate,
        timeout: TimeInterval,
        operationDescription: String,
        isCancelled: (@Sendable () -> Bool)?,
        acceptedStatusCodes: Set<Int>
    ) throws -> (data: Data, response: HTTPURLResponse) {
        task.resume()

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isCancelled?() == true {
                task.cancel()
                throw CancellationError()
            }

            if delegate.completed {
                break
            }

            if Date() >= deadline {
                task.cancel()
                throw RemoteClientError.operationTimedOut(operation: operationDescription, seconds: timeout)
            }

            _ = delegate.completionSemaphore.wait(timeout: .now() + 0.1)
        }

        if let error = delegate.error {
            if error is CancellationError {
                throw error
            }
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw RemoteClientError.requestFailed(details: error.localizedDescription)
        }

        if let downloadError = delegate.downloadMoveError {
            throw downloadError
        }

        guard let response = delegate.response as? HTTPURLResponse else {
            throw RemoteClientError.requestFailed(details: String(localized: "The WebDAV server returned an invalid HTTP response."))
        }

        guard acceptedStatusCodes.contains(response.statusCode) else {
            throw webDAVError(response: response, body: delegate.receivedData)
        }

        return (delegate.receivedData, response)
    }

    private func authorizedRequest(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        bodyData: Data? = nil
    ) throws -> URLRequest {
        _ = try validatedEndpointURL()
        guard !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteClientError.requestFailed(details: String(localized: "The Username field is empty."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.fileTransferTimeout
        request.httpBody = bodyData
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let password = config.password ?? ""
        let credentials = "\(config.username):\(password)"
        let encodedCredentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func resourceURL(forRemotePath remotePath: String, isDirectoryHint: Bool?) throws -> URL {
        let normalizedPath = normalizedRemotePath(remotePath)
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        let basePath = endpointURL.path
        let relativePath = normalizedPath == "/" ? "" : encodedRemotePath(normalizedPath)
        var fullPath = basePath + relativePath
        if fullPath.isEmpty {
            fullPath = "/"
        }
        if isDirectoryHint == true && !fullPath.hasSuffix("/") {
            fullPath += "/"
        }
        components?.percentEncodedPath = fullPath
        guard let url = components?.url else {
            throw RemoteClientError.requestFailed(details: String(localized: "Failed to build the WebDAV request URL."))
        }
        return url
    }

    private func encodedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return "/" + trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { encodeWebDAVPathComponent(String($0)) }
            .joined(separator: "/")
    }

    private func encodeWebDAVPathComponent(_ component: String) -> String {
        S3RequestSigner.uriEncode(component, encodeSlash: false)
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func makeRemoteLocation(path: String) -> RemoteLocation {
        let normalizedPath = normalizedRemotePath(path)
        return RemoteLocation(
            id: normalizedPath,
            path: "dav://\(config.normalizedHost)\(normalizedPath)",
            remotePath: normalizedPath,
            directoryURL: nil
        )
    }

    private func webDAVError(response: HTTPURLResponse, body: Data) -> RemoteClientError {
        let bodyText = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch response.statusCode {
        case 401:
            return .requestFailed(details: String(localized: "WebDAV authentication failed for \(config.username)@\(config.normalizedHost):\(config.port). Verify the username and password."))
        case 403:
            return .requestFailed(details: String(localized: "The WebDAV server denied access to this path."))
        case 404:
            return .requestFailed(details: String(localized: "The requested WebDAV path was not found on the server."))
        case 405:
            return .requestFailed(details: String(localized: "The WebDAV server rejected this operation for the target path."))
        case 409:
            return .requestFailed(details: String(localized: "The WebDAV server reported a path conflict. Verify that the parent folder exists and the destination name is valid."))
        case 412:
            return .requestFailed(details: String(localized: "The WebDAV destination already exists."))
        default:
            let details = bodyText?.isEmpty == false
                ? bodyText!
                : HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            return .requestFailed(details: String(localized: "WebDAV request failed (\(response.statusCode)): \(details)"))
        }
    }

    private func validatedEndpointURL() throws -> URL {
        if let endpointResolutionError {
            throw endpointResolutionError
        }
        return endpointURL
    }
}

private enum S3RootMode: Equatable {
    case service
    case bucket(String)

    var isBucketScoped: Bool {
        switch self {
        case .service:
            return false
        case .bucket:
            return true
        }
    }
}

private enum S3RootListing {
    case service([S3Bucket])
    case bucket(bucket: String, response: S3ListObjectsResponse)
}

private final class BlockingURLSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate {
    let completionSemaphore = DispatchSemaphore(value: 0)
    let progress: (@Sendable (TransferProgressSnapshot) -> Void)?
    let destinationURL: URL?

    private let lock = NSLock()
    private var storedResponse: URLResponse?
    private var storedReceivedData = Data()
    private var storedError: Error?
    private var storedCompleted = false
    private var storedDownloadMoveError: Error?

    var response: URLResponse? {
        withLock { storedResponse }
    }

    var receivedData: Data {
        withLock { storedReceivedData }
    }

    var error: Error? {
        withLock { storedError }
    }

    var completed: Bool {
        withLock { storedCompleted }
    }

    var downloadMoveError: Error? {
        withLock { storedDownloadMoveError }
    }

    init(
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        destinationURL: URL?
    ) {
        self.progress = progress
        self.destinationURL = destinationURL
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        withLock {
            storedReceivedData.append(data)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        withLock {
            storedResponse = response
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        withLock {
            storedResponse = downloadTask.response
        }
        guard let destinationURL else { return }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
        } catch {
            withLock {
                storedDownloadMoveError = error
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(
            .init(
                completedByteCount: totalBytesWritten,
                totalByteCount: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(
            .init(
                completedByteCount: totalBytesSent,
                totalByteCount: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil
            )
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        withLock {
            storedResponse = task.response
            storedError = error
            storedCompleted = true
        }
        completionSemaphore.signal()
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private struct S3Bucket {
    let name: String
    let createdAt: Date?
}

private struct S3ObjectEntry {
    let key: String
    let size: Int64
    let lastModified: Date?
}

private struct S3ListObjectsResponse {
    let commonPrefixes: [String]
    let objects: [S3ObjectEntry]
    let isTruncated: Bool
    let nextContinuationToken: String?
}

private enum S3RequestSigner {
    static func sign(
        method: String,
        url: URL,
        headers: [String: String],
        payloadHash: String,
        accessKey: String,
        secretKey: String,
        region: String,
        dateStamp: String,
        amzDate: String
    ) throws -> String {
        let sortedHeaders = headers
            .map { ($0.key.lowercased(), canonicalHeaderValue($0.value)) }
            .sorted { $0.0 < $1.0 }
        let canonicalHeaders = sortedHeaders
            .map { "\($0.0):\($0.1)\n" }
            .joined()
        let signedHeaders = sortedHeaders.map(\.0).joined(separator: ";")
        let canonicalQuery = canonicalQueryString(from: url)
        let canonicalRequest = [
            method,
            canonicalURI(from: url),
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let hashedCanonicalRequest = SHA256.hash(data: Data(canonicalRequest.utf8)).hexDigest
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            hashedCanonicalRequest
        ].joined(separator: "\n")

        let signingKey = signatureKey(
            secretKey: secretKey,
            dateStamp: dateStamp,
            region: region,
            service: "s3"
        )
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey)).hexDigest
        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private static func signatureKey(secretKey: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        let dateKey = hmac(key: Data(("AWS4" + secretKey).utf8), message: dateStamp)
        let dateRegionKey = hmac(key: dateKey, message: region)
        let dateRegionServiceKey = hmac(key: dateRegionKey, message: service)
        let signingKeyData = hmac(key: dateRegionServiceKey, message: "aws4_request")
        return SymmetricKey(data: signingKeyData)
    }

    private static func hmac(key: Data, message: String) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(signature)
    }

    private static func canonicalURI(from url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let normalizedPath = path.isEmpty ? "/" : path
        return normalizedPath.replacingOccurrences(of: "+", with: "%20")
    }

    private static func canonicalQueryString(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let items = components.queryItems ?? []
        guard !items.isEmpty else { return "" }

        let encodedItems = items.map { item -> (String, String) in
            let name = uriEncode(item.name, encodeSlash: true)
            let value = uriEncode(item.value ?? "", encodeSlash: true)
            return (name, value)
        }
        return encodedItems
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 {
                    return lhs.1 < rhs.1
                }
                return lhs.0 < rhs.0
            }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
        var result = ""
        for scalar in string.unicodeScalars {
            if unreserved.unicodeScalars.contains(scalar) || (!encodeSlash && scalar == "/") {
                result.unicodeScalars.append(scalar)
                continue
            }

            for byte in String(scalar).utf8 {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func canonicalHeaderValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private enum S3ListBucketsXMLParser {
    static func parse(data: Data) throws -> [S3Bucket] {
        let document = try XMLNodeDocument.parse(data: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return document.nodes(named: "Bucket").compactMap { node in
            guard let name = node.firstValue(named: "Name"), !name.isEmpty else { return nil }
            let createdAtText = node.firstValue(named: "CreationDate")
            let createdAt = createdAtText.flatMap {
                formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            return S3Bucket(name: name, createdAt: createdAt)
        }
    }
}

private enum S3ListObjectsXMLParser {
    static func parse(data: Data) throws -> S3ListObjectsResponse {
        let document = try XMLNodeDocument.parse(data: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        let commonPrefixes = document
            .nodes(named: "CommonPrefixes")
            .compactMap { $0.firstValue(named: "Prefix") }

        let objects = document
            .nodes(named: "Contents")
            .compactMap { node -> S3ObjectEntry? in
                guard let key = node.firstValue(named: "Key"), !key.isEmpty else { return nil }
                let size = Int64(node.firstValue(named: "Size") ?? "") ?? 0
                let modifiedAtText = node.firstValue(named: "LastModified")
                let modifiedAt = modifiedAtText.flatMap {
                    formatter.date(from: $0) ?? fallbackFormatter.date(from: $0)
                }
                return S3ObjectEntry(key: key, size: size, lastModified: modifiedAt)
            }

        let isTruncated = (document.firstValue(named: "IsTruncated") ?? "").lowercased() == "true"
        let nextContinuationToken = document.firstValue(named: "NextContinuationToken")

        return S3ListObjectsResponse(
            commonPrefixes: commonPrefixes,
            objects: objects,
            isTruncated: isTruncated,
            nextContinuationToken: nextContinuationToken
        )
    }
}

private enum WebDAVPROPFINDXMLParser {
    static func parse(
        data: Data,
        endpointURL: URL,
        requestedRemotePath: String
    ) throws -> [BrowserItem] {
        let document = try XMLNodeDocument.parse(data: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatterWithoutFractions = ISO8601DateFormatter()

        return document.nodes(named: "response").compactMap { node -> BrowserItem? in
            guard let href = node.firstValue(named: "href") else { return nil }
            guard let remotePath = logicalRemotePath(fromHref: href, endpointURL: endpointURL) else { return nil }
            if remotePath == requestedRemotePath {
                return nil
            }

            let isDirectory = node
                .nodes(named: "resourcetype")
                .contains { !$0.nodes(named: "collection").isEmpty }
            let name = node.firstValue(named: "displayname").flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? {
                let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return trimmed.isEmpty ? "/" : (trimmed as NSString).lastPathComponent
            }()
            let byteCount = Int64(node.firstValue(named: "getcontentlength") ?? "")
            let modifiedText = node.firstValue(named: "getlastmodified")
            let modifiedAt = modifiedText.flatMap {
                formatter.date(from: $0)
                    ?? fallbackFormatter.date(from: $0)
                    ?? fallbackFormatterWithoutFractions.date(from: $0)
            }

            return BrowserItem(
                id: remotePath,
                name: name,
                kind: webDAVFileKind(for: name, isDirectory: isDirectory),
                byteCount: isDirectory ? nil : byteCount,
                modifiedAt: modifiedAt,
                sizeDescription: isDirectory ? "--" : webDAVSizeDescription(byteCount),
                modifiedDescription: webDAVModifiedDescription(for: modifiedAt),
                pathDescription: remotePath,
                url: nil
            )
        }
    }

    private static func logicalRemotePath(fromHref href: String, endpointURL: URL) -> String? {
        guard let hrefURL = URL(string: href, relativeTo: endpointURL)?.absoluteURL else {
            return nil
        }

        let endpointPath = normalizedEndpointBasePath(endpointURL.path)
        let absolutePath = normalizedPath(hrefURL.path)
        let relativePath: String

        if endpointPath == "/" {
            relativePath = absolutePath
        } else if absolutePath == endpointPath || absolutePath == endpointPath + "/" {
            relativePath = "/"
        } else if absolutePath.hasPrefix(endpointPath + "/") {
            relativePath = String(absolutePath.dropFirst(endpointPath.count))
        } else {
            relativePath = absolutePath
        }

        return normalizedPath(relativePath.removingPercentEncoding ?? relativePath)
    }

    private static func normalizedEndpointBasePath(_ path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/"
        }
        let standardized = NSString(string: path).standardizingPath
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private static func normalizedPath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private static func webDAVFileKind(for name: String, isDirectory: Bool) -> FileKind {
        if isDirectory {
            return .folder
        }

        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg":
            return .image
        case "zip", "tar", "gz", "tgz", "rar", "7z", "xz":
            return .archive
        case "swift", "js", "ts", "json", "sh", "py", "rb", "go", "rs", "yml", "yaml", "toml":
            return .code
        default:
            return .document
        }
    }

    private static func webDAVSizeDescription(_ byteCount: Int64?) -> String {
        guard let byteCount else { return "--" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static func webDAVModifiedDescription(for date: Date?) -> String {
        guard let date else { return "--" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        if Calendar.current.isDateInToday(date) {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            timeFormatter.dateStyle = .none
            return "\(String(localized: "Today")), \(timeFormatter.string(from: date))"
        }

        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }

        if abs(date.timeIntervalSinceNow) < 7 * 24 * 60 * 60 {
            return formatter.localizedString(for: date, relativeTo: Date()).capitalized
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }
}

private struct XMLNodeDocument {
    fileprivate let root: XMLNode

    static func parse(data: Data) throws -> XMLNodeDocument {
        let delegate = XMLTreeParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            let details = parser.parserError?.localizedDescription ?? "Failed to parse XML."
            throw RemoteClientError.requestFailed(details: details)
        }
        return XMLNodeDocument(root: root)
    }

    func nodes(named name: String) -> [XMLNode] {
        root.allDescendants(named: name)
    }

    func firstValue(named name: String) -> String? {
        root.firstValue(named: name)
    }
}

private struct XMLNode {
    let name: String
    var value: String
    var children: [XMLNode]

    func nodes(named target: String) -> [XMLNode] {
        children.filter { $0.name == target }
    }

    func allDescendants(named target: String) -> [XMLNode] {
        var matches: [XMLNode] = []
        if name == target {
            matches.append(self)
        }
        for child in children {
            matches.append(contentsOf: child.allDescendants(named: target))
        }
        return matches
    }

    func firstValue(named target: String) -> String? {
        if name == target, !value.isEmpty {
            return value
        }
        for child in children {
            if let value = child.firstValue(named: target) {
                return value
            }
        }
        return nil
    }
}

private final class XMLTreeParserDelegate: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private(set) var root: XMLNode?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(XMLNode(name: normalizedElementName(elementName, qualifiedName: qName), value: "", children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].value += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        var trimmed = node
        trimmed.value = node.value.trimmingCharacters(in: .whitespacesAndNewlines)

        if stack.isEmpty {
            root = trimmed
        } else {
            stack[stack.count - 1].children.append(trimmed)
        }
    }

    private func normalizedElementName(_ elementName: String, qualifiedName: String?) -> String {
        let rawName = qualifiedName ?? elementName
        return rawName.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? rawName
    }
}

private func sha256Hex(forFileAt url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty {
            break
        }
        hasher.update(data: chunk)
    }
    return hasher.finalize().hexDigest
}

private func localFileByteCount(for url: URL) throws -> Int64 {
    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        return Int64(size)
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let fileSize = attributes[.size] as? NSNumber {
        return fileSize.int64Value
    }

    throw NSError(
        domain: "S3HTTPSession",
        code: CocoaError.fileReadUnknown.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "Unable to determine file size for \(url.lastPathComponent)."]
    )
}

private extension Digest {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private final class CitadelSFTPSession: @unchecked Sendable {
    private static let connectionTimeout: TimeInterval = 15
    private static let directoryTimeout: TimeInterval = 15
    private static let mutationTimeout: TimeInterval = 20
    private static let fileTransferTimeout: TimeInterval = 600
    private let config: RemoteConnectionConfig
    private let lock = NSLock()
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    init(config: RemoteConnectionConfig) {
        self.config = config
    }

    deinit {
        let sshClient = withLock {
            let client = self.sshClient
            self.sshClient = nil
            self.sftpClient = nil
            return client
        }

        guard let sshClient else { return }
        Task.detached {
            try? await sshClient.close()
        }
    }

    func loadDirectorySnapshot(in location: RemoteLocation) throws -> RemoteDirectorySnapshot {
        try withConnectedSFTP(timeout: Self.directoryTimeout, operationDescription: "Loading remote directory") { sftp in
            let homePath = try await sftp.getRealPath(atPath: ".")
            let targetPath = try await sftp.getRealPath(atPath: location.remotePath)

            let entries = try await sftp.listDirectory(atPath: targetPath)
            let items = entries
                .flatMap(\.components)
                .compactMap { self.makeBrowserItem(from: $0, in: targetPath) }

            return RemoteDirectorySnapshot(
                location: RemoteLocation(
                    id: targetPath,
                    path: "sftp://\(self.config.host)\(targetPath)",
                    remotePath: targetPath,
                    directoryURL: nil
                ),
                items: items,
                homePath: homePath
            )
        }
    }

    func uploadItem(
        at localURL: URL,
        toPath remotePath: String,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        let totalByteCount = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        try withConnectedSFTP(timeout: Self.fileTransferTimeout, operationDescription: "Uploading \(localURL.lastPathComponent)") { sftp in
            let remoteFile = try await sftp.openFile(
                filePath: remotePath,
                flags: [.write, .create, .truncate]
            )
            defer {
                Task.detached {
                    try? await remoteFile.close()
                }
            }

            let localHandle = try FileHandle(forReadingFrom: localURL)
            defer {
                try? localHandle.close()
            }

            let chunkSize = 64 * 1024
            var offset: UInt64 = 0
            var completedByteCount: Int64 = 0
            progress?(.init(completedByteCount: 0, totalByteCount: totalByteCount))

            while true {
                if isCancelled?() == true {
                    throw CancellationError()
                }
                let data = try localHandle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }

                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: offset)

                offset += UInt64(data.count)
                completedByteCount += Int64(data.count)
                progress?(.init(completedByteCount: completedByteCount, totalByteCount: totalByteCount))
            }

            if completedByteCount == 0 {
                progress?(.init(completedByteCount: 0, totalByteCount: totalByteCount ?? 0))
            }
        }
    }

    func downloadItem(
        at remotePath: String,
        to destinationURL: URL,
        progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        do {
            try withConnectedSFTP(timeout: Self.fileTransferTimeout, operationDescription: "Downloading \(destinationURL.lastPathComponent)") { sftp in
                let remoteFile = try await sftp.openFile(filePath: remotePath, flags: .read)
                defer {
                    Task.detached {
                        try? await remoteFile.close()
                    }
                }

                let attributes = try await remoteFile.readAttributes()
                let totalByteCount = attributes.size.map(Int64.init)
                FileManager.default.createFile(atPath: destinationURL.path(percentEncoded: false), contents: nil)
                let outputHandle = try FileHandle(forWritingTo: destinationURL)
                defer {
                    try? outputHandle.close()
                }

                let chunkSize: UInt32 = 64 * 1024
                var offset: UInt64 = 0
                var completedByteCount: Int64 = 0
                progress?(.init(completedByteCount: 0, totalByteCount: totalByteCount))

                while true {
                    if isCancelled?() == true {
                        throw CancellationError()
                    }
                    let buffer = try await remoteFile.read(from: offset, length: chunkSize)
                    if buffer.readableBytes == 0 { break }
                    let data = buffer.withUnsafeReadableBytes { Data($0) }
                    try outputHandle.write(contentsOf: data)

                    offset += UInt64(data.count)
                    completedByteCount += Int64(data.count)
                    progress?(.init(completedByteCount: completedByteCount, totalByteCount: totalByteCount))
                }

                if completedByteCount == 0 {
                    progress?(.init(completedByteCount: 0, totalByteCount: totalByteCount ?? 0))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    func createDirectory(at remotePath: String) throws {
        try withConnectedSFTP(timeout: Self.mutationTimeout, operationDescription: "Creating remote folder") { sftp in
            try await sftp.createDirectory(atPath: remotePath)
        }
    }

    func renameItem(at remotePath: String, to destinationPath: String) throws {
        try withConnectedSFTP(timeout: Self.mutationTimeout, operationDescription: "Renaming remote item") { sftp in
            try await sftp.rename(at: remotePath, to: destinationPath)
        }
    }

    func deleteItem(at remotePath: String, isDirectory: Bool, recursively: Bool) throws {
        try withConnectedSFTP(timeout: Self.mutationTimeout, operationDescription: "Deleting remote item") { sftp in
            if isDirectory {
                if recursively {
                    try await self.deleteDirectoryRecursively(at: remotePath, using: sftp)
                } else {
                    try await sftp.rmdir(at: remotePath)
                }
            } else {
                try await sftp.remove(at: remotePath)
            }
        }
    }

    private func deleteDirectoryRecursively(at remotePath: String, using sftp: SFTPClient) async throws {
        let entries = try await sftp.listDirectory(atPath: remotePath)
        let children = entries
            .flatMap(\.components)
            .compactMap { self.makeBrowserItem(from: $0, in: remotePath) }

        for child in children {
            if child.isDirectory {
                try await deleteDirectoryRecursively(at: child.pathDescription, using: sftp)
            } else {
                try await sftp.remove(at: child.pathDescription)
            }
        }

        try await sftp.rmdir(at: remotePath)
    }

    private func withConnectedSFTP<T>(
        timeout: TimeInterval,
        operationDescription: String,
        operation: @escaping @Sendable (SFTPClient) async throws -> T
    ) throws -> T {
        try runBlocking(timeout: timeout, operationDescription: operationDescription) {
            let sftp = try await self.connectIfNeeded()
            return try await operation(sftp)
        }
    }

    private func connectIfNeeded() async throws -> SFTPClient {
        if let connectedClient = withLock({ sftpClient }), connectedClient.isActive {
            return connectedClient
        }

        let connectHost: String
        do {
            connectHost = try config.resolvedConnectHost()
        } catch {
            throw normalizedError(error)
        }
        let connectionTimeout = Self.connectionTimeout
        let connectionOperation = "Connecting to \(config.normalizedHost)"
        let authenticationMethod: SSHAuthenticationMethod
        do {
            authenticationMethod = try self.authenticationMethod()
        } catch {
            throw normalizedError(error)
        }

        let settings = SSHClientSettings(
            host: connectHost,
            port: config.port,
            authenticationMethod: { authenticationMethod },
            hostKeyValidator: .acceptAnything()
        )

        do {
            let sshClient = try await withThrowingTaskGroup(of: SSHClient.self) { group in
                group.addTask {
                    try await SSHClient.connect(to: settings)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(connectionTimeout))
                    throw RemoteClientError.operationTimedOut(
                        operation: connectionOperation,
                        seconds: connectionTimeout
                    )
                }

                guard let firstResult = try await group.next() else {
                    throw RemoteClientError.requestFailed(details: "Citadel did not return a connection result.")
                }
                group.cancelAll()
                return firstResult
            }
            let sftpClient = try await sshClient.openSFTP()
            withLock {
                self.sshClient = sshClient
                self.sftpClient = sftpClient
            }
            return sftpClient
        } catch {
            withLock {
                self.sshClient = nil
                self.sftpClient = nil
            }
            throw normalizedError(error)
        }
    }

    private func runBlocking<T>(
        timeout: TimeInterval,
        operationDescription: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingResultBox<T>()
        let task = Task.detached(priority: .userInitiated) {
            do {
                box.result = Result.success(try await operation())
            } catch {
                box.result = Result.failure(error)
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            task.cancel()
            throw RemoteClientError.operationTimedOut(
                operation: operationDescription,
                seconds: timeout
            )
        }

        guard let result = box.result else {
            throw RemoteClientError.requestFailed(details: "Citadel operation did not produce a result.")
        }
        do {
            return try result.get()
        } catch {
            throw normalizedError(error)
        }
    }

    private func normalizedError(_ error: Error) -> Error {
        if let remoteClientError = error as? RemoteClientError {
            return remoteClientError
        }

        let localizedMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailedMessage = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        for message in [detailedMessage, localizedMessage] where !message.isEmpty {
            if let diagnosticMessage = diagnosticMessage(for: message) {
                return RemoteClientError.requestFailed(details: diagnosticMessage)
            }
        }
        if !detailedMessage.isEmpty, detailedMessage != localizedMessage {
            return RemoteClientError.requestFailed(details: detailedMessage)
        }
        if localizedMessage.isEmpty || localizedMessage == "The operation couldn’t be completed." {
            return RemoteClientError.requestFailed(details: "The remote server did not complete the SFTP request.")
        }
        return RemoteClientError.requestFailed(details: localizedMessage)
    }

    private func diagnosticMessage(for message: String) -> String? {
        let lowercased = message.lowercased()
        let host = config.normalizedHost
        let endpointSummary = "\(host):\(config.port)"

        if config.hostRequiresNormalization {
            return "Invalid host format. Use only the hostname in the Host field, for example \(host), not \(config.host)."
        }

        if lowercased.contains("authentication") || lowercased.contains("auth fail") || lowercased.contains("unable to authenticate") {
            return "SFTP authentication failed for \(config.username)@\(endpointSummary). Verify the selected authentication method, account, and SSH key or password."
        }

        if lowercased.contains("sshclienterror error 4") || lowercased.contains("allauthenticationoptionsfailed") {
            if config.authenticationMode == .sshKey {
                return "SSH key authentication was rejected by \(endpointSummary). Verify that the server accepts this user key, the username matches, and the server allows RSA public key login for this account."
            }
            return "Password authentication was rejected by \(endpointSummary). Verify the username and password."
        }

        if lowercased.contains("sshclienterror error 1") || lowercased.contains("unsupportedprivatekeyauthentication") {
            return "The SSH server at \(endpointSummary) does not accept public key authentication for this session, or it rejected the offered key algorithm."
        }

        if lowercased.contains("connection refused") {
            return "Connection to \(endpointSummary) was refused. Verify that the SSH/SFTP service is listening on that host and port."
        }

        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return "Connection to \(endpointSummary) timed out. Verify the host, port, network reachability, and any firewall rules."
        }

        if lowercased.contains("no route to host") || lowercased.contains("network is unreachable") {
            return "Cannot reach \(endpointSummary). Verify the host, port, and network route."
        }

        if lowercased.contains("name or service not known") || lowercased.contains("nodename nor servname") || lowercased.contains("unknown host") {
            return "The host \(host) could not be resolved. Check the Host field and DNS."
        }

        if lowercased.contains("disconnected error 1") || lowercased.contains("clienthandshakehandler") {
            return "SSH handshake failed before the SFTP session was established for \(config.username)@\(endpointSummary). Verify the host, port, username, and selected password or SSH key."
        }

        return nil
    }

    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        switch config.authenticationMode {
        case .password:
            let password = config.password ?? ""
            guard !password.isEmpty else {
                throw RemoteClientError.requestFailed(details: "SFTP password is required when password authentication is selected.")
            }
            return SSHAuthenticationMethod.passwordBased(
                username: config.username,
                password: password
            )
        case .sshKey:
            return try loadSSHKeyAuthenticationMethod()
        }
    }

    private func loadSSHKeyAuthenticationMethod() throws -> SSHAuthenticationMethod {
        let trimmedPath = (config.privateKeyPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw RemoteClientError.requestFailed(details: "Select a private key file for SSH key authentication.")
        }

        let keyURL = URL(fileURLWithPath: expandingCurrentUserHomeDirectory(in: trimmedPath))
        // Access the selected URL itself. Do not resolve a link before reading: its
        // target may be outside the security scope granted by the file picker.
        let keyContents = try readSecurityScopedTextFile(
            at: keyURL,
            bookmarkData: config.privateKeyBookmarkData
        )
        let passphraseData = config.password?.isEmpty == false ? Data((config.password ?? "").utf8) : nil

        if keyContents.contains("BEGIN OPENSSH PRIVATE KEY") {
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyContents)
            switch keyType {
            case .rsa:
                return .rsa(
                    username: config.username,
                    privateKey: try Insecure.RSA.PrivateKey(sshRsa: keyContents, decryptionKey: passphraseData)
                )
            case .ed25519:
                return .ed25519(
                    username: config.username,
                    privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: keyContents, decryptionKey: passphraseData)
                )
            case .ecdsaP256, .ecdsaP384, .ecdsaP521:
                throw RemoteClientError.requestFailed(details: "OpenSSH ECDSA private keys are not supported by the current SFTP adapter. Export the key as PEM or use an RSA/ED25519 OpenSSH key.")
            default:
                throw RemoteClientError.requestFailed(details: "Unsupported OpenSSH private key type for SFTP authentication.")
            }
        }

        if keyContents.contains("BEGIN EC PRIVATE KEY") || keyContents.contains("BEGIN PRIVATE KEY") {
            if let auth = try pemECDSAAuthenticationMethod(from: keyContents) {
                return auth
            }
        }

        if let auth = try securityRSAPrivateKeyAuthenticationMethod(
            from: keyContents,
            keyURL: keyURL,
            passphrase: config.password
        ) {
            return auth
        }

        throw RemoteClientError.requestFailed(details: "Unsupported private key format. Use a PEM RSA/ECDSA key or an OpenSSH RSA/ED25519 private key.")
    }

    private func pemECDSAAuthenticationMethod(from pem: String) throws -> SSHAuthenticationMethod? {
        if let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return .p256(username: config.username, privateKey: privateKey)
        }
        if let privateKey = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return .p384(username: config.username, privateKey: privateKey)
        }
        if let privateKey = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return .p521(username: config.username, privateKey: privateKey)
        }
        return nil
    }

    private func securityRSAPrivateKeyAuthenticationMethod(
        from pem: String,
        keyURL: URL,
        passphrase: String?
    ) throws -> SSHAuthenticationMethod? {
        let privateKey = try importedRSAPrivateKey(from: pem, passphrase: passphrase) ?? {
            guard let derData = pemDERData(from: pem) else {
                return nil
            }

            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
            ]
            return SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, nil)
        }()
        guard let privateKey else {
            return nil
        }

        let publicKeyBlob = try resolvedRSAPublicKeyBlob(for: keyURL, privateKey: privateKey)
        let delegate = SecKeyRSAAuthenticationDelegate(
            username: config.username,
            privateKey: privateKey,
            publicKeyBlob: publicKeyBlob
        )
        return .custom(delegate)
    }

    private func importedRSAPrivateKey(from pem: String, passphrase: String?) throws -> SecKey? {
        var externalFormat = SecExternalFormat.formatUnknown
        var itemType = SecExternalItemType.itemTypeUnknown
        var importedItems: CFArray?
        var keyParameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
            flags: SecKeyImportExportFlags(rawValue: 0),
            passphrase: nil,
            alertTitle: nil,
            alertPrompt: nil,
            accessRef: nil,
            keyUsage: nil,
            keyAttributes: nil
        )

        let status: OSStatus
        if let passphrase, !passphrase.isEmpty {
            keyParameters.passphrase = Unmanaged.passUnretained(passphrase as CFString)
            status = SecItemImport(
                pem.data(using: .utf8)! as CFData,
                nil,
                &externalFormat,
                &itemType,
                [],
                &keyParameters,
                nil,
                &importedItems
            )
        } else {
            status = SecItemImport(
                pem.data(using: .utf8)! as CFData,
                nil,
                &externalFormat,
                &itemType,
                [],
                nil,
                nil,
                &importedItems
            )
        }

        guard status == errSecSuccess else {
            if status == errSecPassphraseRequired {
                throw RemoteClientError.requestFailed(details: "This RSA private key is encrypted. Enter the key passphrase in the Key Passphrase field and try again.")
            }
            if isRSAPrivateKeyPEM(pem) {
                throw rsaPEMImportError(status: status, passphrase: passphrase)
            }
            return nil
        }

        if let importedKey = (importedItems as? [SecKey])?.first {
            return isRSASecKey(importedKey) ? importedKey : nil
        }
        if let importedDictionary = (importedItems as? [[String: Any]])?.first {
            guard let identity = importedDictionary[kSecImportItemIdentity as String] else {
                return nil
            }
            let identityRef = identity as CFTypeRef
            guard CFGetTypeID(identityRef) == SecIdentityGetTypeID() else {
                return nil
            }
            var importedKey: SecKey?
            let identityStatus = SecIdentityCopyPrivateKey(unsafeBitCast(identityRef, to: SecIdentity.self), &importedKey)
            guard identityStatus == errSecSuccess, let importedKey else {
                return nil
            }
            return isRSASecKey(importedKey) ? importedKey : nil
        }
        return nil
    }

    private func isRSAPrivateKeyPEM(_ pem: String) -> Bool {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("BEGIN RSA PRIVATE KEY")
            || trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY")
    }

    private func rsaPEMImportError(status: OSStatus, passphrase: String?) -> RemoteClientError {
        if status == errSecAuthFailed {
            let details: String
            if let passphrase, !passphrase.isEmpty {
                details = "The Key Passphrase is incorrect for the selected RSA private key."
            } else {
                details = "This RSA private key is encrypted. Enter the key passphrase in the Key Passphrase field and try again."
            }
            return .requestFailed(details: details)
        }

        let statusMessage = (SecCopyErrorMessageString(status, nil) as String?) ?? "Security framework error \(status)."
        return .requestFailed(details: "Failed to import the RSA private key: \(statusMessage)")
    }

    private func isRSASecKey(_ key: SecKey) -> Bool {
        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        return (attributes?[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeRSA as String)
    }

    private func resolvedRSAPublicKeyBlob(for privateKeyURL: URL, privateKey: SecKey) throws -> SSHPublicKeyBlob {
        let candidateURLs: [(url: URL, bookmarkData: Data?)] = [
            config.publicKeyPath.map { path in
                (
                    URL(fileURLWithPath: expandingCurrentUserHomeDirectory(in: path)),
                    config.publicKeyBookmarkData
                )
            },
            (URL(fileURLWithPath: privateKeyURL.path(percentEncoded: false) + ".pub"), nil)
        ].compactMap { $0 }

        for candidate in candidateURLs {
            guard let contents = try? readSecurityScopedTextFile(
                at: candidate.url,
                bookmarkData: candidate.bookmarkData
            ) else { continue }
            if let blob = try? SSHPublicKeyBlob(openSSHPublicKey: contents, expectedPrefix: "ssh-rsa") {
                return blob
            }
        }

        if let derivedBlob = try derivedRSAPublicKeyBlob(from: privateKey) {
            return derivedBlob
        }

        throw RemoteClientError.requestFailed(details: "Unable to derive the RSA public key from the PEM private key. If you have the matching .pub file, select it in Public Key and try again.")
    }

    private func derivedRSAPublicKeyBlob(from privateKey: SecKey) throws -> SSHPublicKeyBlob? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let derRepresentation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        return try SSHPublicKeyBlob(rsaPublicKeyDER: derRepresentation)
    }

    private func pemDERData(from pem: String) -> Data? {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("BEGIN "), trimmed.contains("PRIVATE KEY") else {
            return nil
        }

        let base64Payload = trimmed
            .split(separator: "\n")
            .map(String.init)
            .filter {
                !$0.hasPrefix("-----BEGIN")
                    && !$0.hasPrefix("-----END")
                    && !$0.contains(":")
            }
            .joined()
        return Data(base64Encoded: base64Payload)
    }

    private func makeBrowserItem(from component: SFTPPathComponent, in remotePath: String) -> BrowserItem? {
        let name = component.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let fullPath = normalizedRemotePath(
            name.hasPrefix("/") ? name : join(remotePath: remotePath, name: name)
        )
        let isDirectory = isDirectory(component)
        let byteCount = component.attributes.size.map(Int64.init)

        return BrowserItem(
            id: fullPath,
            name: (fullPath as NSString).lastPathComponent,
            kind: fileKind(for: name, isDirectory: isDirectory),
            byteCount: isDirectory ? nil : byteCount,
            modifiedAt: component.attributes.accessModificationTime?.modificationTime,
            sizeDescription: isDirectory ? "--" : sizeDescription(byteCount),
            modifiedDescription: modifiedDescription(for: component.attributes.accessModificationTime?.modificationTime),
            pathDescription: fullPath,
            url: nil
        )
    }

    private func isDirectory(_ component: SFTPPathComponent) -> Bool {
        if let permissions = component.attributes.permissions {
            return permissions & 0o170000 == 0o040000
        }
        return component.longname.hasPrefix("d")
    }

    private func fileKind(for name: String, isDirectory: Bool) -> FileKind {
        if isDirectory {
            return .folder
        }

        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg":
            return .image
        case "zip", "tar", "gz", "tgz", "rar", "7z", "xz":
            return .archive
        case "swift", "js", "ts", "json", "sh", "py", "rb", "go", "rs", "yml", "yaml", "toml":
            return .code
        default:
            return .document
        }
    }

    private func sizeDescription(_ byteCount: Int64?) -> String {
        guard let byteCount else { return "--" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func modifiedDescription(for date: Date?) -> String {
        guard let date else { return "--" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        if Calendar.current.isDateInToday(date) {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            timeFormatter.dateStyle = .none
            return "\(String(localized: "Today")), \(timeFormatter.string(from: date))"
        }

        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }

        if abs(date.timeIntervalSinceNow) < 7 * 24 * 60 * 60 {
            return formatter.localizedString(for: date, relativeTo: Date()).capitalized
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }

    private func join(remotePath: String, name: String) -> String {
        if remotePath == "/" {
            return "/\(name)"
        }
        return "\(remotePath)/\(name)"
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        if standardized.isEmpty || standardized == "." {
            return "/"
        }
        return standardized.hasPrefix("/") ? standardized : "/\(standardized)"
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class BlockingResultBox<Value>: @unchecked Sendable {
    nonisolated(unsafe) var result: Result<Value, Error>?
}

private struct SSHPublicKeyBlob {
    let prefix: String
    let body: Data

    init(prefix: String, body: Data) {
        self.prefix = prefix
        self.body = body
    }

    init(rsaPublicKeyDER: Data) throws {
        let parser = try RSAPKCS1PublicKeyParser(derBytes: rsaPublicKeyDER)
        self.prefix = "ssh-rsa"
        self.body = Self.makeRSABody(
            publicExponent: parser.publicExponent,
            modulus: parser.modulus
        )
    }

    init(openSSHPublicKey: String, expectedPrefix: String) throws {
        let components = openSSHPublicKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw RemoteClientError.requestFailed(details: "The selected public key file is not a valid OpenSSH public key.")
        }

        let prefix = String(components[0])
        guard prefix == expectedPrefix else {
            throw RemoteClientError.requestFailed(details: "The selected public key does not match the private key algorithm \(expectedPrefix).")
        }
        guard let rawData = Data(base64Encoded: String(components[1])) else {
            throw RemoteClientError.requestFailed(details: "The selected public key file could not be decoded.")
        }

        guard let encodedPrefix = Self.readSSHString(from: rawData, offset: 0) else {
            throw RemoteClientError.requestFailed(details: "The selected public key file has an invalid SSH wire format.")
        }
        guard let encodedPrefixString = String(data: encodedPrefix.data, encoding: .utf8),
              encodedPrefixString == prefix
        else {
            throw RemoteClientError.requestFailed(details: "The selected public key file has an invalid SSH wire format.")
        }

        self.prefix = prefix
        self.body = rawData.subdata(in: encodedPrefix.nextOffset..<rawData.count)
    }

    private static func makeRSABody(publicExponent: Data, modulus: Data) -> Data {
        var body = Data()
        body.append(sshMPInt(publicExponent))
        body.append(sshMPInt(modulus))
        return body
    }

    private static func sshMPInt(_ integer: Data) -> Data {
        let normalized = normalizeUnsignedInteger(integer)
        let payload: Data
        if normalized.first.map({ $0 & 0x80 != 0 }) == true {
            payload = Data([0]) + normalized
        } else {
            payload = normalized
        }

        var encoded = Data()
        encoded.append(sshUInt32(UInt32(payload.count)))
        encoded.append(payload)
        return encoded
    }

    private static func normalizeUnsignedInteger(_ integer: Data) -> Data {
        let trimmed = integer.drop { $0 == 0 }
        return trimmed.isEmpty ? Data([0]) : Data(trimmed)
    }

    private static func sshUInt32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func readSSHString(from data: Data, offset: Int) -> (data: Data, nextOffset: Int)? {
        guard offset + 4 <= data.count else { return nil }
        let lengthData = data.subdata(in: offset..<(offset + 4))
        let length = lengthData.withUnsafeBytes { rawBuffer -> UInt32 in
            rawBuffer.load(as: UInt32.self).bigEndian
        }
        let start = offset + 4
        let end = start + Int(length)
        guard end <= data.count else { return nil }
        return (data.subdata(in: start..<end), end)
    }
}

private struct RSAPKCS1PublicKeyParser {
    let modulus: Data
    let publicExponent: Data

    init(derBytes: Data) throws {
        var offset = 0
        try Self.consumeTag(0x30, in: derBytes, offset: &offset)
        _ = try Self.readLength(in: derBytes, offset: &offset)
        self.modulus = try Self.readInteger(in: derBytes, offset: &offset)
        self.publicExponent = try Self.readInteger(in: derBytes, offset: &offset)
    }

    private static func readInteger(in data: Data, offset: inout Int) throws -> Data {
        try consumeTag(0x02, in: data, offset: &offset)
        let length = try readLength(in: data, offset: &offset)
        guard offset + length <= data.count else {
            throw RemoteClientError.requestFailed(details: "Failed to parse the derived RSA public key.")
        }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }

    private static func consumeTag(_ expected: UInt8, in data: Data, offset: inout Int) throws {
        guard offset < data.count, data[offset] == expected else {
            throw RemoteClientError.requestFailed(details: "Failed to parse the derived RSA public key.")
        }
        offset += 1
    }

    private static func readLength(in data: Data, offset: inout Int) throws -> Int {
        guard offset < data.count else {
            throw RemoteClientError.requestFailed(details: "Failed to parse the derived RSA public key.")
        }

        let firstByte = data[offset]
        offset += 1
        if firstByte & 0x80 == 0 {
            return Int(firstByte)
        }

        let byteCount = Int(firstByte & 0x7f)
        guard byteCount > 0, offset + byteCount <= data.count else {
            throw RemoteClientError.requestFailed(details: "Failed to parse the derived RSA public key.")
        }

        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }
}

private final class SecKeyRSAAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKeys: [NIOSSHPrivateKey]
    private var nextKeyIndex = 0

    init(username: String, privateKey: SecKey, publicKeyBlob: SSHPublicKeyBlob) {
        self.username = username
        self.privateKeys = [
            NIOSSHPrivateKey(
                custom: SecKeyRSAPrivateKeyRSA512(
                    privateKey: privateKey,
                    publicKey: SecKeyRSAPublicKeyRSA512(blob: publicKeyBlob)
                )
            ),
            NIOSSHPrivateKey(
                custom: SecKeyRSAPrivateKeyRSA256(
                    privateKey: privateKey,
                    publicKey: SecKeyRSAPublicKeyRSA256(blob: publicKeyBlob)
                )
            )
        ]
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
            return
        }

        guard nextKeyIndex < privateKeys.count else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }

        let privateKey = privateKeys[nextKeyIndex]
        nextKeyIndex += 1

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

private protocol SecKeyRSAAlgorithmTag {
    static var userAuthAlgorithm: String { get }
    static var signatureAlgorithm: SecKeyAlgorithm { get }
}

private enum SecKeyRSA512Algorithm: SecKeyRSAAlgorithmTag {
    static let userAuthAlgorithm = "rsa-sha2-512"
    static let signatureAlgorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA512
}

private enum SecKeyRSA256Algorithm: SecKeyRSAAlgorithmTag {
    static let userAuthAlgorithm = "rsa-sha2-256"
    static let signatureAlgorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
}

private struct SecKeyRSAPublicKey<Algorithm: SecKeyRSAAlgorithmTag>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.userAuthAlgorithm }

    let blob: SSHPublicKeyBlob

    var rawRepresentation: Data { blob.body }

    func isValidSignature<D>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool where D: DataProtocol {
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(blob.body)
    }

    static func read(from buffer: inout ByteBuffer) throws -> SecKeyRSAPublicKey {
        guard let data = buffer.readData(length: buffer.readableBytes) else {
            throw RemoteClientError.requestFailed(details: "Failed to decode RSA public key data.")
        }
        return SecKeyRSAPublicKey(blob: SSHPublicKeyBlob(prefix: publicKeyPrefix, body: data))
    }
}

private typealias SecKeyRSAPublicKeyRSA512 = SecKeyRSAPublicKey<SecKeyRSA512Algorithm>
private typealias SecKeyRSAPublicKeyRSA256 = SecKeyRSAPublicKey<SecKeyRSA256Algorithm>

private struct SecKeyRSAPrivateKey<Algorithm: SecKeyRSAAlgorithmTag>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Algorithm.userAuthAlgorithm }

    let privateKey: SecKey
    let publicKey: NIOSSHPublicKeyProtocol

    func signature<D>(for data: D) throws -> NIOSSHSignatureProtocol where D: DataProtocol {
        let payload = Data(data)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            Algorithm.signatureAlgorithm,
            payload as CFData,
            &error
        ) as Data?
        else {
            let details = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "RSA private key signing failed."
            throw RemoteClientError.requestFailed(details: details)
        }
        return SecKeyRSASignature<Algorithm>(rawRepresentation: signature)
    }
}

private typealias SecKeyRSAPrivateKeyRSA512 = SecKeyRSAPrivateKey<SecKeyRSA512Algorithm>
private typealias SecKeyRSAPrivateKeyRSA256 = SecKeyRSAPrivateKey<SecKeyRSA256Algorithm>

private struct SecKeyRSASignature<Algorithm: SecKeyRSAAlgorithmTag>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Algorithm.userAuthAlgorithm }

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        writeSSHString(rawRepresentation, to: &buffer)
    }

    static func read(from buffer: inout ByteBuffer) throws -> SecKeyRSASignature {
        guard let data = readSSHString(from: &buffer) else {
            throw RemoteClientError.requestFailed(details: "Failed to decode RSA signature data.")
        }
        return SecKeyRSASignature(rawRepresentation: data)
    }
}

@discardableResult
private func writeSSHString(_ data: Data, to buffer: inout ByteBuffer) -> Int {
    buffer.writeInteger(UInt32(data.count))
    return 4 + buffer.writeBytes(data)
}

private func readSSHString(from buffer: inout ByteBuffer) -> Data? {
    guard let length = buffer.readInteger(as: UInt32.self) else { return nil }
    return buffer.readData(length: Int(length))
}

private extension RemoteConnectionConfig {
    func resolvedWebDAVEndpointURL() throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteClientError.requestFailed(details: "The Host field is empty.")
        }

        let defaultScheme = port == 80 ? "http" : "https"
        let rawEndpoint = trimmed.contains("://") ? trimmed : "\(defaultScheme)://\(trimmed)"
        guard var components = URLComponents(string: rawEndpoint) else {
            throw RemoteClientError.requestFailed(details: String(localized: "The WebDAV endpoint is not a valid URL."))
        }
        guard let resolvedHost = components.host, !resolvedHost.isEmpty else {
            throw RemoteClientError.requestFailed(details: String(localized: "The WebDAV endpoint is missing a host name."))
        }

        if components.port == nil {
            components.port = port
        }
        if components.path.isEmpty {
            components.path = ""
        }

        guard let url = components.url else {
            throw RemoteClientError.requestFailed(details: String(localized: "Failed to build the WebDAV endpoint URL."))
        }
        _ = resolvedHost
        return url
    }

    func resolvedHTTPEndpointURL() throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteClientError.requestFailed(details: "The Host field is empty.")
        }

        let scheme = port == 80 ? "http" : "https"
        let rawEndpoint = trimmed.contains("://") ? trimmed : "\(scheme)://\(trimmed)"
        guard var components = URLComponents(string: rawEndpoint) else {
            throw RemoteClientError.requestFailed(details: "The S3 endpoint is not a valid URL.")
        }
        guard let resolvedHost = components.host, !resolvedHost.isEmpty else {
            throw RemoteClientError.requestFailed(details: "The S3 endpoint is missing a host name.")
        }

        if components.port == nil {
            components.port = port
        }
        if components.path.isEmpty {
            components.path = ""
        }
        guard let url = components.url else {
            throw RemoteClientError.requestFailed(details: "Failed to build the S3 endpoint URL.")
        }
        return url
    }

    func resolvedConnectHost() throws -> String {
        let host = normalizedHost
        guard !host.isEmpty else {
            throw RemoteClientError.requestFailed(details: "The Host field is empty.")
        }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resultPointer)
        guard status == 0, let resultPointer else {
            let details = String(cString: gai_strerror(status))
            throw RemoteClientError.requestFailed(
                details: "The host \(host) could not be resolved for SFTP: \(details)."
            )
        }
        defer { freeaddrinfo(resultPointer) }

        let preferred = numericHosts(from: resultPointer, preference: addressPreference)
        guard let connectHost = preferred.first else {
            throw RemoteClientError.requestFailed(
                details: "The host \(host) resolved, but no usable network address was returned for SFTP."
            )
        }
        return connectHost
    }

    var normalizedHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") else { return trimmed }

        if
            let components = URLComponents(string: trimmed),
            let normalizedHost = components.host,
            !normalizedHost.isEmpty
        {
            return normalizedHost
        }

        let withoutScheme = trimmed.replacingOccurrences(
            of: #"^[A-Za-z][A-Za-z0-9+\-.]*://"#,
            with: "",
            options: .regularExpression
        )
        let hostPortAndPath = withoutScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutScheme
        let hostOnly = hostPortAndPath.split(separator: "@").last.map(String.init) ?? hostPortAndPath
        return hostOnly.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
    }

    var hostRequiresNormalization: Bool {
        normalizedHost != host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var urlScheme: String {
        switch connectionKind {
        case .sftp:
            return "sftp"
        case .webdav:
            return "dav"
        case .cloud:
            return "s3"
        }
    }
}

private func numericHosts(
    from head: UnsafeMutablePointer<addrinfo>,
    preference: ConnectionAddressPreference
) -> [String] {
    var resolvedHosts: [String] = []
    var ipv4Hosts: [String] = []
    var ipv6Hosts: [String] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = head

    while let entry = cursor?.pointee {
        defer { cursor = entry.ai_next }

        let family = entry.ai_family
        guard family == AF_INET || family == AF_INET6 else { continue }
        guard let address = entry.ai_addr else { continue }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            address,
            entry.ai_addrlen,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { continue }

        let host = String(cString: hostBuffer)
        resolvedHosts.append(host)
        if family == AF_INET {
            ipv4Hosts.append(host)
        } else {
            ipv6Hosts.append(host)
        }
    }

    let orderedHosts: [String]
    switch preference {
    case .automatic:
        orderedHosts = resolvedHosts
    case .ipv4:
        orderedHosts = ipv4Hosts + ipv6Hosts
    case .ipv6:
        orderedHosts = ipv6Hosts + ipv4Hosts
    }

    return Array(NSOrderedSet(array: orderedHosts)) as? [String] ?? orderedHosts
}
