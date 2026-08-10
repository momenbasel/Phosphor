from __future__ import annotations

from pathlib import Path
import plistlib
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_backup_comparison_engine_classifies_snapshot_changes_behaviorally(root: Path) -> None:
    model = root / "Sources/Phosphor/Models/BackupComparison.swift"
    assert model.exists(), "BackupComparison model/engine must exist"

    probe = r'''
import Foundation

@main
struct Probe {
    static func main() {
        let old = [
            BackupComparisonRecord(fileID: "stable", domain: "HomeDomain", relativePath: "same.txt", flags: 1, size: 5, modifiedTime: 10),
            BackupComparisonRecord(fileID: "changed", domain: "HomeDomain", relativePath: "changed.txt", flags: 1, size: 5, modifiedTime: 10),
            BackupComparisonRecord(fileID: "removed", domain: "CameraRollDomain", relativePath: "old.jpg", flags: 1, size: 8, modifiedTime: 10),
        ]
        let new = [
            BackupComparisonRecord(fileID: "stable", domain: "HomeDomain", relativePath: "same.txt", flags: 1, size: 5, modifiedTime: 10),
            BackupComparisonRecord(fileID: "changed", domain: "HomeDomain", relativePath: "changed.txt", flags: 1, size: 9, modifiedTime: 11),
            BackupComparisonRecord(fileID: "added", domain: "CameraRollDomain", relativePath: "new.jpg", flags: 1, size: 12, modifiedTime: 12),
        ]
        let result = BackupComparisonEngine.compare(older: old, newer: new)
        print("COUNTS|\(result.addedCount)|\(result.modifiedCount)|\(result.removedCount)|\(result.unchangedCount)")
        print("ORDER|" + result.changes.map { "\($0.kind.rawValue):\($0.relativePath)" }.joined(separator: ","))

        let manyNew = (0..<4).map {
            BackupComparisonRecord(fileID: "new-\($0)", domain: "HomeDomain", relativePath: "new-\($0).txt", flags: 1, size: 1, modifiedTime: 1)
        }
        let capped = BackupComparisonEngine.compare(older: [], newer: manyNew, displayLimitPerKind: 2)
        print("CAP|\(capped.addedCount)|\(capped.changes.count)|\(capped.hasHiddenChanges)")

        var oldIterator = old.sorted { $0.cursorOrderKey < $1.cursorOrderKey }.makeIterator()
        var newIterator = new.sorted { $0.cursorOrderKey < $1.cursorOrderKey }.makeIterator()
        let streamed = try! BackupComparisonEngine.compareOrdered(
            nextOlder: { oldIterator.next() },
            nextNewer: { newIterator.next() }
        )
        print("STREAM|\(streamed.addedCount)|\(streamed.modifiedCount)|\(streamed.removedCount)|\(streamed.unchangedCount)")

        let oversizedOld = BackupComparisonRecord(fileID: "large", domain: "HomeDomain", relativePath: "large.bin", flags: 1, size: 0, modifiedTime: nil, metadataComplete: false)
        let oversizedNew = BackupComparisonRecord(fileID: "large", domain: "HomeDomain", relativePath: "large.bin", flags: 1, size: 0, modifiedTime: nil, metadataComplete: false)
        let conservative = BackupComparisonEngine.compare(older: [oversizedOld], newer: [oversizedNew])
        print("INCOMPLETE|\(conservative.modifiedCount)|\(conservative.unchangedCount)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "backup-comparison-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(model), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "COUNTS|1|1|1|1" in result.stdout, result.stdout
    assert "ORDER|added:new.jpg,modified:changed.txt,removed:old.jpg" in result.stdout, result.stdout
    assert "CAP|4|2|true" in result.stdout, result.stdout
    assert "STREAM|1|1|1|1" in result.stdout, result.stdout
    assert "INCOMPLETE|1|0" in result.stdout, result.stdout


def test_backup_comparison_uses_manifest_metadata_off_main_actor(root: Path) -> None:
    manifest = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    model = read(root, "Sources/Phosphor/Models/BackupComparison.swift")
    service = read(root, "Sources/Phosphor/Services/BackupComparisonService.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupComparisonView.swift")
    time_machine = read(root, "Sources/Phosphor/Views/Backup/BackupTimeMachineView.swift")

    assert "final class ComparisonCursor" in manifest
    assert "func makeComparisonCursor()" in manifest
    assert "func comparisonRecords() throws -> [BackupComparisonRecord]" not in manifest
    assert "CASE WHEN length(file)" in manifest and "maximumMetadataBlobBytes" in manifest
    assert "flags = 1" in manifest, "comparison should report regular files, not directories or links"
    assert "makeComparisonCursor" in service
    assert "BackupComparisonEngine.compareOrdered" in service
    assert "Task.checkCancellation()" in model, "streaming merge must stop promptly when dismissed"
    assert "Task.detached" in view, "large manifest comparisons must not block SwiftUI's main actor"
    assert "comparisonOperationID" in view, "stale comparison completions must be ignored"
    assert "comparisonTask" in view and ".cancel()" in view, "dismissed/replaced comparisons must cancel background work"
    assert "Task.checkCancellation()" in manifest and "sqlite3_step" in manifest, "manifest scans must be bounded and cancellation-aware"
    assert "status == SQLITE_DONE" in manifest and "status == SQLITE_ROW" in manifest
    assert "SQLITE_OPEN_READONLY" in manifest, "comparison cursor must not mutate a backup manifest"
    assert "Compare Backups" in time_machine, "Time Machine must expose the comparison flow"
    assert "BackupComparisonView" in time_machine, "the comparison UI must be reachable"
    assert "BackupUnlockStore.shared" in view and "BackupPasswordKeychain" in view
    assert "Unlock Encrypted Backup" in view


def test_backup_comparison_rejects_mismatched_devices(root: Path) -> None:
    service = read(root, "Sources/Phosphor/Services/BackupComparisonService.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupComparisonView.swift")
    assert "case differentDevices" in service
    assert "older.udid == newer.udid" in service
    assert "fileResourceIdentifier" in service and "volumeIdentifier" in service
    assert "resolvingSymlinksInPath" in service
    assert "case invalidChronology" in service and "olderDate < newerDate" in service
    assert "($0.lastBackupDate ?? .distantFuture) < newerDate" in view
    assert "Same device" in view or "same device" in view


def test_backup_comparison_decodes_uid_backed_modification_dates(root: Path) -> None:
    crypto = root / "Sources/Phosphor/Utilities/BackupCrypto.swift"
    plist_parser = root / "Sources/Phosphor/Utilities/PlistParser.swift"
    model = root / "Sources/Phosphor/Models/BackupComparison.swift"
    probe = r'''
import Foundation

@main
struct Probe {
    static func main() throws {
        let oldRecord = BackupFileRecord(fileBlob: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
        let newRecord = BackupFileRecord(fileBlob: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))!
        let old = BackupComparisonRecord(fileID: "same", domain: "HomeDomain", relativePath: "same.txt", flags: 1, size: oldRecord.size, modifiedTime: oldRecord.modifiedTime)
        let new = BackupComparisonRecord(fileID: "same", domain: "HomeDomain", relativePath: "same.txt", flags: 1, size: newRecord.size, modifiedTime: newRecord.modifiedTime)
        let result = BackupComparisonEngine.compare(older: [old], newer: [new])
        print("DATES|\(oldRecord.modifiedTime ?? -1)|\(newRecord.modifiedTime ?? -1)")
        print("COUNTS|\(result.modifiedCount)|\(result.unchangedCount)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        blobs = []
        for index, reference_time in enumerate((100.0, 200.0)):
            blob = temp / f"record-{index}.plist"
            blob.write_bytes(
                plistlib.dumps(
                    {
                        "$objects": [
                            "$null",
                            {
                                "ProtectionClass": 1,
                                "Size": 5,
                                "LastModified": plistlib.UID(2),
                            },
                            {"NS.time": reference_time},
                        ],
                        "$top": {"root": plistlib.UID(1)},
                        "$version": 100000,
                        "$archiver": "NSKeyedArchiver",
                    },
                    fmt=plistlib.FMT_BINARY,
                )
            )
            blobs.append(blob)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "backup-date-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(crypto), str(plist_parser), str(model), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run(
            [str(executable), str(blobs[0]), str(blobs[1])],
            capture_output=True,
            text=True,
            timeout=10,
        )

    assert result.returncode == 0, result.stderr
    assert "DATES|978307300.0|978307400.0" in result.stdout, result.stdout
    assert "COUNTS|1|0" in result.stdout, result.stdout


def test_backup_operation_gate_covers_all_manager_instances(root: Path) -> None:
    coordinator = root / "Sources/Phosphor/Services/BackupOperationCoordinator.swift"
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    service = read(root, "Sources/Phosphor/Services/BackupComparisonService.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupComparisonView.swift")
    assert coordinator.exists()
    assert manager.count("BackupOperationCoordinator.shared.beginBackup()") >= 2
    assert "BackupOperationCoordinator.shared.beginComparison()" in service
    assert "backupOperationStateDidChange" in view and "backupOperationActive" in view

    probe = r'''
import Foundation

@main
struct Probe {
    static func main() {
        let coordinator = BackupOperationCoordinator.shared
        let backup = coordinator.beginBackup()!
        print("BACKUP_BLOCKS_COMPARE|\(coordinator.beginComparison() == nil)")
        coordinator.endBackup(backup)

        // A comparison must never cost the user a backup. It is a read-only
        // pass over two archived snapshots and is restartable; a scheduled
        // backup is not, and BackupScheduler advances lastRunDate even when the
        // run fails, so a refused backup silently skips a whole cycle.
        let comparison = coordinator.beginComparison()!
        let preempting = coordinator.beginBackup()
        print("BACKUP_PREEMPTS_COMPARE|\(preempting != nil)")
        print("COMPARISON_INVALIDATED|\(!coordinator.comparisonIsValid(comparison))")
        coordinator.endBackup(preempting!)
        coordinator.endComparison(comparison)
        print("RELEASED|\(coordinator.beginBackup() != nil)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "backup-operation-gate-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(coordinator), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "BACKUP_BLOCKS_COMPARE|true" in result.stdout
    assert "BACKUP_PREEMPTS_COMPARE|true" in result.stdout
    assert "COMPARISON_INVALIDATED|true" in result.stdout
    assert "RELEASED|true" in result.stdout
