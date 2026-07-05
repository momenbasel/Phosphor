import Foundation

/// Thread-safe, bounded, UTF-8-safe line buffer for high-rate process output streaming.
///
/// Producers (a pipe `readabilityHandler` on a background queue) feed raw `Data` via
/// `append(_:)`. The buffer splits it into complete `\n`-terminated lines, keeping any
/// trailing partial bytes as a remainder so a multi-byte UTF-8 scalar split across two
/// reads is never dropped. Complete lines accumulate in a bounded FIFO (oldest dropped
/// past `capacity`). A consumer periodically calls `drain()` on the main queue.
///
/// Pairing this with a *single-in-flight* main-queue flush in the caller bounds the
/// number of queued main blocks to one regardless of producer rate — which is what
/// prevents the unbounded main-queue backlog that exhausted memory during syslog
/// streaming (the diagnostics "47 GB" freeze).
final class StreamingLineBuffer: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var remainder = Data()
    private var lines: [String] = []
    private let newline: UInt8 = 0x0A

    init(capacity: Int = 5000) {
        self.capacity = max(1, capacity)
    }

    /// Number of complete lines currently buffered (test/diagnostic hook).
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    /// Feed raw bytes from the background reader. Splits into complete lines and
    /// retains any trailing partial bytes until their line is completed.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }

        var buffer = remainder
        buffer.append(data)

        var start = buffer.startIndex
        var produced: [String] = []
        while let nl = buffer[start...].firstIndex(of: newline) {
            produced.append(String(decoding: buffer[start..<nl], as: UTF8.self))
            start = buffer.index(after: nl)
        }
        // Bytes after the last newline are an incomplete line; keep for next read.
        remainder = Data(buffer[start...])

        guard !produced.isEmpty else { return }
        lines.append(contentsOf: produced)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    /// Drain and return all buffered complete lines, clearing the buffer.
    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = lines
        lines.removeAll(keepingCapacity: true)
        return out
    }

    /// Flush any trailing partial bytes as a final line (call on stream end).
    func finish() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if !remainder.isEmpty {
            lines.append(String(decoding: remainder, as: UTF8.self))
            remainder.removeAll(keepingCapacity: false)
        }
        let out = lines
        lines.removeAll(keepingCapacity: true)
        return out
    }
}
