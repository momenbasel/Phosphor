import Foundation

struct BackupOperationRegistry {
    private var operationByDevice: [String: UUID] = [:]

    mutating func acquire(udid: String, operationID: UUID) -> Bool {
        guard operationByDevice[udid] == nil else { return false }
        operationByDevice[udid] = operationID
        return true
    }

    mutating func release(udid: String, operationID: UUID) -> Bool {
        guard operationByDevice[udid] == operationID else { return false }
        operationByDevice.removeValue(forKey: udid)
        return true
    }
}

struct BackupOperationCoordinator {
    private(set) var activeOperationID: UUID?
    private var activeUDID: String?

    mutating func begin(
        udid: String,
        operationID: UUID = UUID(),
        registry: inout BackupOperationRegistry
    ) -> UUID? {
        guard activeOperationID == nil else { return nil }
        guard registry.acquire(udid: udid, operationID: operationID) else { return nil }

        activeOperationID = operationID
        activeUDID = udid
        return operationID
    }

    @discardableResult
    mutating func finish(
        operationID: UUID,
        registry: inout BackupOperationRegistry
    ) -> Bool {
        guard activeOperationID == operationID, let activeUDID else { return false }
        guard registry.release(udid: activeUDID, operationID: operationID) else { return false }

        self.activeOperationID = nil
        self.activeUDID = nil
        return true
    }
}
