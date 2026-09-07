import Foundation
import Testing
@testable import FilePier

private final class TransferTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

private actor TransferTestFile {
    var data: Data
    var writeOffsets: [UInt64] = []
    init(_ data: Data = Data()) { self.data = data }
    func read(_ offset: UInt64, _ count: Int) -> Data {
        guard offset < data.count else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
    }
    func write(_ offset: UInt64, _ bytes: Data) {
        writeOffsets.append(offset)
        let end = Int(offset) + bytes.count
        if data.count < end { data.append(Data(count: end - data.count)) }
        data.replaceSubrange(Int(offset)..<end, with: bytes)
    }
}

struct ResumableTransferTests {
    @Test func progressingTransferOutlives600Seconds() {
        let clock = TransferTestClock()
        let monitor = TransferActivityMonitor(now: { clock.read() })
        for _ in 0..<100 {
            clock.advance(100)
            #expect(!monitor.hasExpired(after: 600))
            monitor.touch()
        }
        clock.advance(600)
        #expect(monitor.hasExpired(after: 600))
    }

    @Test func pauseDoesNotConsumeInactivityBudget() {
        let clock = TransferTestClock()
        let monitor = TransferActivityMonitor(now: { clock.read() })
        monitor.report(.init(completedByteCount: 1, totalByteCount: 10)) { _ in
            clock.advance(3_600)
            #expect(!monitor.hasExpired(after: 600))
        }
        #expect(!monitor.hasExpired(after: 600))
        clock.advance(599)
        #expect(!monitor.hasExpired(after: 600))
        clock.advance(1)
        #expect(monitor.hasExpired(after: 600))
    }

    @Test func interruptedCopyResumesWithoutRewritingPrefix() async throws {
        let contents = Data((0..<200_003).map { UInt8($0 % 251) })
        let source = TransferTestFile(contents)
        let partial = TransferTestFile()
        let activity = TransferActivityMonitor()
        do {
            try await ResumableTransferCopy.copy(from: 0, totalSize: UInt64(contents.count),
                activity: activity, progress: nil, isCancelled: nil,
                read: { await source.read($0, $1) },
                write: { offset, bytes in
                    if offset >= 96_000 { throw CocoaError(.fileWriteUnknown) }
                    await partial.write(offset, bytes)
                })
            Issue.record("The simulated disconnect should fail the first attempt")
        } catch {}
        let partialSize = await partial.data.count
        #expect(partialSize == 96_000)
        let offset = try await ResumableTransferCopy.validatedOffset(existingSize: UInt64(partialSize),
            totalSize: UInt64(contents.count), source: { await source.read($0, $1) },
            destination: { await partial.read($0, $1) })
        #expect(offset == 96_000)
        try await ResumableTransferCopy.copy(from: offset, totalSize: UInt64(contents.count),
            activity: activity, progress: nil, isCancelled: nil,
            read: { await source.read($0, $1) }, write: { await partial.write($0, $1) })
        #expect(await partial.data == contents)
        #expect(await partial.writeOffsets == [0, 32_000, 64_000, 96_000, 128_000, 160_000, 192_000])
    }

    @Test func corruptOrOversizedPartialRestarts() async throws {
        let source = TransferTestFile(Data(repeating: 42, count: 100_000))
        for size in [20_000, 90_000, 110_000] {
            let partial = TransferTestFile(Data(repeating: 99, count: size))
            let offset = try await ResumableTransferCopy.validatedOffset(existingSize: UInt64(size), totalSize: 100_000,
                source: { await source.read($0, $1) }, destination: { await partial.read($0, $1) })
            #expect(offset == 0)
        }
    }

    @Test func shortSFTPReadsAreSupportedDuringValidationAndCopy() async throws {
        let source = TransferTestFile(Data(repeating: 42, count: 45_001))
        let partial = TransferTestFile(Data(repeating: 42, count: 32_001))
        let offset = try await ResumableTransferCopy.validatedOffset(existingSize: 32_001, totalSize: 45_001,
            source: { await source.read($0, min($1, 997)) }, destination: { await partial.read($0, min($1, 811)) })
        #expect(offset == 32_001)
        try await ResumableTransferCopy.copy(from: offset, totalSize: 45_001,
            activity: TransferActivityMonitor(), progress: nil, isCancelled: nil,
            read: { await source.read($0, min($1, 997)) }, write: { await partial.write($0, $1) })
        #expect(await partial.data == source.data)
    }

    @Test func unexpectedEOFDoesNotPublishSuccess() async throws {
        let source = TransferTestFile(Data(repeating: 1, count: 10))
        let partial = TransferTestFile()
        await #expect(throws: (any Error).self) {
            try await ResumableTransferCopy.copy(from: 0, totalSize: 100,
                activity: TransferActivityMonitor(), progress: nil, isCancelled: nil,
                read: { await source.read($0, $1) }, write: { await partial.write($0, $1) })
        }
        #expect(await partial.data.count == 10)
    }

    @Test func cancellationAfterReadPreventsFurtherWrites() async throws {
        let partial = TransferTestFile()
        let cancellation = TransferTestClock()
        await #expect(throws: CancellationError.self) {
            try await ResumableTransferCopy.copy(from: 0, totalSize: 100,
                activity: TransferActivityMonitor(), progress: nil, isCancelled: { cancellation.read() > 0 },
                read: { _, count in
                    cancellation.advance(1)
                    return Data(count: count)
                }, write: { await partial.write($0, $1) })
        }
        #expect(await partial.writeOffsets.isEmpty)
    }

    @Test func cancelledAsyncTaskDoesNotStartReading() async throws {
        let partial = TransferTestFile()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ResumableTransferCopy.copy(from: 0, totalSize: 100,
                activity: TransferActivityMonitor(), progress: nil, isCancelled: nil,
                read: { _, count in
                    Issue.record("Cancelled worker must not read")
                    return Data(count: count)
                }, write: { await partial.write($0, $1) })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await partial.writeOffsets.isEmpty)
    }

    @Test func completedAndEmptyFilesNeedNoWrites() async throws {
        for size: UInt64 in [0, 32_000] {
            try await ResumableTransferCopy.copy(from: size, totalSize: size,
                activity: TransferActivityMonitor(), progress: { snapshot in
                    #expect(snapshot.completedByteCount == Int64(size))
                    #expect(snapshot.fractionCompleted == 1)
                }, isCancelled: nil,
                read: { _, _ in Issue.record("No read expected"); return Data() },
                write: { _, _ in Issue.record("No write expected") })
        }
    }

    @Test func partialIdentityPersistsAndSeparatesVersionsAndServers() {
        let identity = ["server", "22", "user", "/file", "1000", "mtime"]
        #expect(ResumableTransferIdentity.partialName(identity) == ResumableTransferIdentity.partialName(identity))
        #expect(ResumableTransferIdentity.partialName(identity) != ResumableTransferIdentity.partialName(identity + ["changed"]))
        #expect(ResumableTransferIdentity.partialName(["ab", "c"]) != ResumableTransferIdentity.partialName(["a", "bc"]))
    }

    @Test func concurrentDestinationLeaseIsRejectedUntilReleased() throws {
        let key = UUID().uuidString
        let lease = try TransferDestinationLease.acquire(key)
        #expect(throws: (any Error).self) { try TransferDestinationLease.acquire(key) }
        lease.release()
        let next = try TransferDestinationLease.acquire(key)
        next.release()
    }

    @Test @MainActor func copyNeverBlocksMainActorWithFileIOOrPauseCallbacks() async throws {
        try await ResumableTransferCopy.copy(from: 0, totalSize: 1,
            activity: TransferActivityMonitor(), progress: { _ in
                #expect(!Thread.isMainThread)
            }, isCancelled: nil,
            read: { _, _ in
                #expect(!Thread.isMainThread)
                return Data([42])
            }, write: { _, _ in
                #expect(!Thread.isMainThread)
            })
    }

    @Test func sourceIdentityUsesFreshMetadataOnRetry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 1, count: 100).write(to: url)
        let first = try ResumableTransferIdentity.localFile(url)
        #expect(try ResumableTransferIdentity.localFile(url) == first)
        _ = try url.resourceValues(forKeys: [.contentModificationDateKey])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        #expect(try ResumableTransferIdentity.localFile(url) != first)
    }

    @Test func HTTPResourceDeadlineIsRemovedWithoutMutatingOriginal() {
        let original = URLSessionConfiguration.ephemeral
        original.timeoutIntervalForResource = 600
        original.timeoutIntervalForRequest = 60
        let copy = transferSessionConfiguration(original)
        #expect(copy.timeoutIntervalForResource > 600)
        #expect(copy.timeoutIntervalForRequest == 60)
        #expect(original.timeoutIntervalForResource == 600)
    }
}
