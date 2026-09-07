import Foundation
import Crypto
import Citadel

nonisolated enum ResumableTransferIdentity {
    static func partialName(_ components: [String]) -> String {
        // Length prefixes avoid ambiguous identities containing separators.
        let value = components.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return ".filepier-\(digest).part"
    }

    static func localFile(_ url: URL) throws -> String {
        // URL resource values may be cached across calls. Read fresh metadata
        // so a source edited during a long upload gets a new identity.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return partialName([url.standardizedFileURL.path, size.stringValue, String(modified.timeIntervalSince1970)])
    }
}

nonisolated enum ResumableTransferCopy {
    typealias Reader = @Sendable (UInt64, Int) async throws -> Data

    @concurrent static func validatedOffset(existingSize: UInt64, totalSize: UInt64,
                                source: Reader, destination: Reader) async throws -> UInt64 {
        guard existingSize > 0, existingSize <= totalSize else { return 0 }
        // Check both the beginning and the resume boundary before trusting a
        // partial file. Source size/mtime are also encoded in its identity.
        let count = Int(min(existingSize, 32_000))
        for offset in Set([UInt64(0), existingSize - UInt64(count)]).sorted() {
            try Task.checkCancellation()
            let expected = try await readExactly(offset: offset, count: count, read: source)
            let actual = try await readExactly(offset: offset, count: count, read: destination)
            guard expected.count == count, actual == expected else { return 0 }
        }
        return existingSize
    }

    private static func readExactly(offset: UInt64, count: Int, read: Reader) async throws -> Data {
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            let chunk = try await read(offset + UInt64(data.count), count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    @concurrent static func copy(from initialOffset: UInt64, totalSize: UInt64, chunkSize: Int = 32_000,
                     activity: TransferActivityMonitor,
                     progress: (@Sendable (TransferProgressSnapshot) -> Void)?,
                     isCancelled: (@Sendable () -> Bool)?,
                     read: Reader, write: @Sendable (UInt64, Data) async throws -> Void) async throws {
        guard initialOffset <= totalSize, totalSize <= UInt64(Int64.max), chunkSize > 0 else {
            throw CocoaError(.fileReadTooLarge)
        }
        var offset = initialOffset
        var lastReport = ProcessInfo.processInfo.systemUptime
        func report() {
            activity.report(.init(completedByteCount: Int64(offset), totalByteCount: Int64(totalSize)), to: progress)
        }
        func checkCancellation() throws {
            try Task.checkCancellation()
            if isCancelled?() == true { throw CancellationError() }
        }
        try checkCancellation()
        report()
        while offset < totalSize {
            try checkCancellation()
            // Citadel splits writes at 32,000 bytes. Matching that boundary
            // avoids an extra tiny round trip for each old 64 KiB chunk.
            let count = Int(min(UInt64(chunkSize), totalSize - offset))
            let data = try await read(offset, count)
            guard !data.isEmpty, data.count <= count else {
                throw RemoteClientError.requestFailed(details: "Source file ended before the expected transfer size.")
            }
            try checkCancellation()
            try await write(offset, data)
            offset += UInt64(data.count)
            activity.touch()
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= 0.1 || offset == totalSize {
                report()
                lastReport = now
            }
        }
        try checkCancellation()
    }
}

/// A timeout can race with opening the channel. Remember cancellation so a
/// channel opened after the timeout is closed immediately as well.
nonisolated final class TransferSFTPChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: SFTPClient?
    private var cancelled = false

    func install(_ channel: SFTPClient) {
        lock.lock()
        self.channel = channel
        let shouldClose = cancelled
        lock.unlock()
        if shouldClose { Task.detached { try? await channel.close() } }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let channel = channel
        lock.unlock()
        if let channel { Task.detached { try? await channel.close() } }
    }
}

nonisolated final class TransferDestinationLease: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var destinations = Set<String>()
    private let key: String

    private init(key: String) { self.key = key }

    static func acquire(_ key: String) throws -> TransferDestinationLease {
        lock.lock()
        defer { lock.unlock() }
        guard destinations.insert(key).inserted else {
            throw RemoteClientError.requestFailed(details: "A transfer to this destination is already running.")
        }
        return TransferDestinationLease(key: key)
    }

    func release() {
        Self.lock.lock()
        Self.destinations.remove(key)
        Self.lock.unlock()
    }
}

nonisolated func transferSessionConfiguration(_ original: URLSessionConfiguration) -> URLSessionConfiguration {
    let configuration = original.copy() as! URLSessionConfiguration
    // The delegate's inactivity watchdog owns transfer lifetime. URLSession's
    // default resource deadline would otherwise abort a healthy long transfer.
    configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
    return configuration
}
