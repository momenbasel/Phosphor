import Foundation

/// Keeps transiently missing values visible for a small number of discovery polls.
///
/// Wireless usbmux devices can disappear for one poll while iOS changes power or
/// network state. Callers provide only currently observed values; this cache returns
/// recently observed values until they exceed the configured missed-scan budget.
struct NetworkDeviceGraceCache<Value> {
    private struct Entry {
        var value: Value
        var missedScans: Int
    }

    private let maxMissedScans: Int
    private var entries: [String: Entry] = [:]
    private var orderedIDs: [String] = []

    init(maxMissedScans: Int) {
        precondition(maxMissedScans >= 0)
        self.maxMissedScans = maxMissedScans
    }

    mutating func merge(current: [(id: String, value: Value)]) -> [Value] {
        let currentIDs = Set(current.map(\.id))
        for (id, value) in current {
            if entries[id] == nil { orderedIDs.append(id) }
            entries[id] = Entry(value: value, missedScans: 0)
        }

        for id in orderedIDs where !currentIDs.contains(id) {
            guard var entry = entries[id] else { continue }
            entry.missedScans += 1
            if entry.missedScans > maxMissedScans {
                entries.removeValue(forKey: id)
            } else {
                entries[id] = entry
            }
        }
        orderedIDs.removeAll { entries[$0] == nil }

        return orderedIDs.compactMap { entries[$0]?.value }
    }

    mutating func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { entries.removeValue(forKey: id) }
        orderedIDs.removeAll { ids.contains($0) }
    }

    mutating func reset() {
        entries.removeAll()
        orderedIDs.removeAll()
    }
}
