import Combine
import Foundation

/// One owner per application, even when multiple browser windows are open.
@MainActor
final class TransferCoordinator: ObservableObject {
    static let shared = TransferCoordinator(store: JSONTransferQueueStore())

    let store: any TransferQueueStore
    let scheduler: TransferScheduler
    @Published var activities: [TransferActivity] = []
    @Published var maxConcurrentTransfers: Int {
        didSet { scheduler.setLimit(maxConcurrentTransfers) }
    }
    var controls: [UUID: TransferControl] = [:]
    var savedTransfers: [UUID: SavedTransfer] = [:]
    var restoredIDs: Set<UUID> = []
    var didRestore = false
    var lastSave = Date.distantPast

    init(store: any TransferQueueStore, maxConcurrentTransfers: Int = 2) {
        self.store = store
        self.maxConcurrentTransfers = maxConcurrentTransfers
        scheduler = TransferScheduler(limit: maxConcurrentTransfers)
    }
}

/// Pending files do not occupy worker threads. Every window, batch and transfer
/// direction shares the same live limit, including after a settings change.
nonisolated final class TransferScheduler: @unchecked Sendable {
    private struct Job: @unchecked Sendable {
        let queue: DispatchQueue
        let operation: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var active = 0
    private var limit: Int
    private var pending: [Job] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func setLimit(_ limit: Int) {
        let ready = lock.withLock {
            self.limit = max(1, limit)
            return takeReadyJobs()
        }
        start(ready)
    }

    func submit(on queue: DispatchQueue, operation: @escaping @Sendable () -> Void) {
        let ready = lock.withLock {
            pending.append(Job(queue: queue, operation: operation))
            return takeReadyJobs()
        }
        start(ready)
    }

    private func takeReadyJobs() -> [Job] {
        var ready: [Job] = []
        while active < limit && !pending.isEmpty {
            active += 1
            ready.append(pending.removeFirst())
        }
        return ready
    }

    private func start(_ jobs: [Job]) {
        for job in jobs {
            job.queue.async {
                job.operation()
                let ready = self.lock.withLock {
                    self.active -= 1
                    return self.takeReadyJobs()
                }
                self.start(ready)
            }
        }
    }
}
