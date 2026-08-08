import Combine
import Foundation

/// Process-wide lease for operations that write iOS backup metadata.
///
/// Backup owners deliberately use separate `BackupManager` instances (manual,
/// scheduled, and clone flows), so instance-local `isCreatingBackup` cannot
/// prevent two subprocesses from targeting the same backup directory.
@MainActor
final class BackupOperationCoordinator: ObservableObject {

    enum Kind: String {
        case backup = "backup"
    }

    struct Lease {
        fileprivate let id: UUID
    }

    static let shared = BackupOperationCoordinator()

    @Published private(set) var activeKind: Kind?
    private var activeLeaseID: UUID?

    var isRunning: Bool {
        activeLeaseID != nil
    }

    private init() {}

    func acquire(kind: Kind = .backup) -> Lease? {
        guard activeLeaseID == nil else { return nil }
        let lease = Lease(id: UUID())
        activeLeaseID = lease.id
        activeKind = kind
        return lease
    }

    func release(_ lease: Lease) {
        guard activeLeaseID == lease.id else { return }
        activeLeaseID = nil
        activeKind = nil
    }
}
