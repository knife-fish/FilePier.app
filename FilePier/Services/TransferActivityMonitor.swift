import Foundation

/// Measures inactivity, excluding time spent in a progress callback (which may
/// deliberately block while the user pauses a transfer).
nonisolated final class TransferActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var lastActivity: TimeInterval
    private var callbackDepth = 0

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        lastActivity = now()
    }

    func touch() {
        lock.lock()
        lastActivity = now()
        lock.unlock()
    }

    func report(_ snapshot: TransferProgressSnapshot, to callback: (@Sendable (TransferProgressSnapshot) -> Void)?) {
        lock.lock()
        callbackDepth += 1
        lock.unlock()
        callback?(snapshot)
        lock.lock()
        callbackDepth -= 1
        lastActivity = now()
        lock.unlock()
    }

    func hasExpired(after timeout: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return callbackDepth == 0 && now() - lastActivity >= timeout
    }
}
