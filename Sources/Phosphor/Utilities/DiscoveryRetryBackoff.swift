import Foundation

/// Schedules compatibility discovery retries without spawning helper processes on every UI poll.
struct DiscoveryRetryBackoff {
    private let initialDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private(set) var consecutiveFailures = 0
    private(set) var nextAttemptAt = Date.distantPast

    init(initialDelay: TimeInterval = 5, maximumDelay: TimeInterval = 120) {
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
    }

    func isDue(at date: Date = Date()) -> Bool {
        date >= nextAttemptAt
    }

    mutating func recordSuccess(at date: Date = Date(), regularInterval: TimeInterval) {
        consecutiveFailures = 0
        nextAttemptAt = date.addingTimeInterval(max(0, regularInterval))
    }

    mutating func recordFailure(at date: Date = Date()) {
        consecutiveFailures = min(consecutiveFailures + 1, 30)
        let exponent = min(consecutiveFailures - 1, 20)
        let delay = min(initialDelay * pow(2, Double(exponent)), maximumDelay)
        nextAttemptAt = date.addingTimeInterval(delay)
    }
}
