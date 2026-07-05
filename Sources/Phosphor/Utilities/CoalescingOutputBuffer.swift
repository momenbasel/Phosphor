import Foundation

/// Thread-safe, bounded, UTF-8-safe coalescing buffer for process output streaming.
///
/// A pipe `readabilityHandler` on a background queue feeds raw `Data` via `append(_:)`.
/// A consumer periodically calls `drainText()` (on the main queue). Unlike a line buffer
/// this preserves the raw text — including `\r`-based progress updates from idevicebackup2 /
/// pymobiledevice3 — so it is safe for every `runStreaming` caller, not just `\n`-based syslog.
///
/// Two properties make it the fix for the diagnostics "47 GB" freeze when paired with a
/// single-in-flight main-queue flush in the caller:
///   * bounded — bytes past `maxBytes` are dropped from the front, so a fast producer can
///     never grow the buffer without limit;
///   * UTF-8-safe — a multi-byte scalar split across two pipe reads is held back until its
///     bytes complete, instead of being decoded to replacement characters or dropped
///     (the pre-existing `String(data:encoding:.utf8)` returned nil and lost the whole chunk).
final class CoalescingOutputBuffer: @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var buffer = Data()

    init(maxBytes: Int = 1_000_000) {
        self.maxBytes = max(16, maxBytes)
    }

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > maxBytes {
            buffer = Data(buffer.suffix(maxBytes))
        }
    }

    /// Decode and return the longest complete-UTF-8 prefix, retaining any trailing
    /// partial scalar for the next read. Clears what it returns.
    func drainText() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return "" }
        let cut = Self.safePrefixLength(buffer)
        guard cut > 0 else { return "" }
        let head = Data(buffer.prefix(cut))
        buffer = Data(buffer.suffix(buffer.count - cut))
        return String(decoding: head, as: UTF8.self)
    }

    /// Flush everything, including any trailing partial bytes (call on stream end).
    func finishText() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return "" }
        let s = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: false)
        return s
    }

    /// Count of leading bytes that end on a complete UTF-8 scalar boundary.
    static func safePrefixLength(_ d: Data) -> Int {
        let bytes = [UInt8](d)
        let n = bytes.count
        if n == 0 { return 0 }
        var i = n - 1
        while i >= 0 && (bytes[i] & 0xC0) == 0x80 { i -= 1 }   // skip continuation bytes
        if i < 0 { return n }                                  // all continuation → take all
        let lead = bytes[i]
        let expected: Int
        if lead & 0x80 == 0 { expected = 1 }
        else if lead & 0xE0 == 0xC0 { expected = 2 }
        else if lead & 0xF0 == 0xE0 { expected = 3 }
        else if lead & 0xF8 == 0xF0 { expected = 4 }
        else { expected = 1 }                                  // invalid lead → treat as single
        let have = n - i
        return have >= expected ? n : i                        // hold back an incomplete last scalar
    }
}
