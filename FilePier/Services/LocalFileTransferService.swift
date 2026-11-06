import Foundation

struct LocalFileTransferResult {
    let sourceURL: URL
    let destinationURL: URL
    let renamedForConflict: Bool
}

struct LocalFileTransferService {
    nonisolated init() {}

    /// Download beside the destination so publishing is an atomic same-volume
    /// move or replacement. Failure and cancellation leave the old file intact.
    func downloadSafely(
        to destinationURL: URL,
        overwrite: Bool,
        isCancelled: (@Sendable () -> Bool)?,
        download: (URL) throws -> Void
    ) throws {
        let lease = try TransferDestinationLease.acquire("download:\(destinationURL.standardizedFileURL.path)")
        defer { lease.release() }
        let stagingDirectory = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".filepier-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)
        if isCancelled?() == true { throw CancellationError() }
        try download(stagedURL)
        if isCancelled?() == true { throw CancellationError() }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
        if overwrite && exists {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    func copyItem(at sourceURL: URL, toDirectory destinationDirectoryURL: URL) throws -> LocalFileTransferResult {
        let fileManager = FileManager.default
        let destinationURL = uniqueDestinationURL(for: sourceURL, in: destinationDirectoryURL)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return LocalFileTransferResult(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            renamedForConflict: destinationURL.lastPathComponent != sourceURL.lastPathComponent
        )
    }

    func renameItem(at sourceURL: URL, toName proposedName: String) throws -> URL {
        let sanitizedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard !sanitizedName.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let destinationDirectoryURL = sourceURL.deletingLastPathComponent()
        let destinationURL = destinationDirectoryURL.appendingPathComponent(
            sanitizedName,
            isDirectory: directoryFlag(for: sourceURL)
        )

        guard destinationURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            return sourceURL
        }

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func deleteItem(at sourceURL: URL, recursively: Bool = true) throws {
        if !recursively, directoryHasContents(at: sourceURL) {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.removeItem(at: sourceURL)
    }

    func directoryHasContents(at directoryURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        return enumerator.nextObject() != nil
    }

    func createDirectory(named proposedName: String, in directoryURL: URL, uniquingIfNeeded: Bool = false) throws -> URL {
        let sanitizedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard !sanitizedName.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let destinationURL = if uniquingIfNeeded {
            uniqueDirectoryURL(forProposedName: sanitizedName, in: directoryURL)
        } else {
            directoryURL.appendingPathComponent(sanitizedName, isDirectory: true)
        }

        guard uniquingIfNeeded || !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        return destinationURL
    }

    func createDirectory(
        named proposedName: String,
        in directoryURL: URL,
        conflictPolicy: TransferConflictPolicy
    ) throws -> URL {
        let sanitizedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty, !sanitizedName.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let destinationURL = directoryURL.appendingPathComponent(sanitizedName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            switch conflictPolicy {
            case .rename:
                return try createDirectory(named: sanitizedName, in: directoryURL, uniquingIfNeeded: true)
            case .overwrite:
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: destinationURL.path(percentEncoded: false),
                    isDirectory: &isDirectory
                )
                if isDirectory.boolValue {
                    return destinationURL
                }
                try FileManager.default.removeItem(at: destinationURL)
            }
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        return destinationURL
    }

    func makeUniqueDestinationURL(forProposedName proposedName: String, in directoryURL: URL) -> URL {
        uniqueDestinationURL(forProposedName: proposedName, in: directoryURL)
    }

    func makeUniqueDirectoryURL(forProposedName proposedName: String, in directoryURL: URL) -> URL {
        uniqueDirectoryURL(forProposedName: proposedName, in: directoryURL)
    }

    func destinationURL(
        forProposedName proposedName: String,
        in directoryURL: URL,
        conflictPolicy: TransferConflictPolicy
    ) throws -> URL {
        let destinationURL = directoryURL.appendingPathComponent(proposedName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return destinationURL
        }

        switch conflictPolicy {
        case .rename:
            return uniqueDestinationURL(forProposedName: proposedName, in: directoryURL)
        case .overwrite:
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false), isDirectory: &isDirectory)
            guard !isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
            return destinationURL
        }
    }

    private func uniqueDestinationURL(for sourceURL: URL, in directoryURL: URL) -> URL {
        uniqueDestinationURL(forProposedName: sourceURL.lastPathComponent, in: directoryURL)
    }

    private func uniqueDestinationURL(forProposedName proposedName: String, in directoryURL: URL) -> URL {
        let fileManager = FileManager.default
        let proposedURL = URL(fileURLWithPath: proposedName)
        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        let pathExtension = proposedURL.pathExtension

        var candidateURL = directoryURL.appendingPathComponent(proposedName, isDirectory: false)
        var duplicateIndex = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            let duplicateName = if pathExtension.isEmpty {
                "\(baseName) \(duplicateIndex)"
            } else {
                "\(baseName) \(duplicateIndex).\(pathExtension)"
            }

            candidateURL = directoryURL.appendingPathComponent(duplicateName, isDirectory: false)
            duplicateIndex += 1
        }

        return candidateURL
    }

    private func uniqueDirectoryURL(forProposedName proposedName: String, in directoryURL: URL) -> URL {
        let fileManager = FileManager.default
        var candidateURL = directoryURL.appendingPathComponent(proposedName, isDirectory: true)
        var duplicateIndex = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = directoryURL.appendingPathComponent("\(proposedName) \(duplicateIndex)", isDirectory: true)
            duplicateIndex += 1
        }

        return candidateURL
    }

    private func directoryFlag(for url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
