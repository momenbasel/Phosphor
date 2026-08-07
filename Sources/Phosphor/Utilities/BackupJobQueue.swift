import Foundation

/// Pure scheduling primitive for bounded, per-device backup concurrency.
struct BackupJobQueue {
    enum EnqueueResult: Equatable {
        case started
        case queued(position: Int)
        case duplicate
    }

    enum CancelResult: Equatable {
        case removedQueued
        case cancelRunning
        case notFound
    }

    let maxConcurrent: Int
    private(set) var runningUDIDs: Set<String> = []
    private(set) var queuedUDIDs: [String] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    mutating func enqueue(udid: String) -> EnqueueResult {
        guard !runningUDIDs.contains(udid), !queuedUDIDs.contains(udid) else {
            return .duplicate
        }
        if runningUDIDs.count < maxConcurrent {
            runningUDIDs.insert(udid)
            return .started
        }
        queuedUDIDs.append(udid)
        return .queued(position: queuedUDIDs.count)
    }

    /// Finishes one running job and atomically promotes the next queued device.
    @discardableResult
    mutating func finish(udid: String) -> String? {
        guard runningUDIDs.remove(udid) != nil else { return nil }
        guard !queuedUDIDs.isEmpty else { return nil }
        let next = queuedUDIDs.removeFirst()
        runningUDIDs.insert(next)
        return next
    }

    mutating func cancel(udid: String) -> CancelResult {
        if let index = queuedUDIDs.firstIndex(of: udid) {
            queuedUDIDs.remove(at: index)
            return .removedQueued
        }
        if runningUDIDs.contains(udid) {
            return .cancelRunning
        }
        return .notFound
    }
}
