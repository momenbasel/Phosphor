from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


def _compile_and_run(root: Path, harness: str) -> str:
    source = root / "Sources/Phosphor/Utilities/BackupLocation.swift"
    assert source.exists(), "BackupLocation.swift must define the tested production classifier"
    with tempfile.TemporaryDirectory(prefix="phosphor-network-location-") as tmp:
        tmp_path = Path(tmp)
        harness_path = tmp_path / "main.swift"
        binary = tmp_path / "probe"
        harness_path.write_text(harness)
        compiled = subprocess.run(
            ["swiftc", str(source), str(harness_path), "-o", str(binary)],
            text=True,
            capture_output=True,
            timeout=60,
        )
        assert compiled.returncode == 0, compiled.stderr
        result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr
        return result.stdout


def _archive_member_listing_is_safe(root: Path, listing: str) -> bool:
    source = root / "Sources/Phosphor/Utilities/ArchiveMemberValidation.swift"
    assert source.exists(), "ArchiveMemberValidation.swift must define the production member-type validator"
    harness = r'''
import Foundation

let data = FileHandle.standardInput.readDataToEndOfFile()
let listing = String(data: data, encoding: .utf8) ?? ""
print(ArchiveMemberValidation.allEntriesAreRegularFilesOrDirectories(listing))
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-archive-member-validation-") as tmp:
        tmp_path = Path(tmp)
        harness_path = tmp_path / "main.swift"
        binary = tmp_path / "probe"
        harness_path.write_text(harness)
        compiled = subprocess.run(
            ["swiftc", str(source), str(harness_path), "-o", str(binary)],
            text=True,
            capture_output=True,
            timeout=60,
        )
        assert compiled.returncode == 0, compiled.stderr
        result = subprocess.run(
            [str(binary)],
            input=listing,
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode == 0, result.stderr
        return result.stdout.strip() == "true"


def _archive_snapshot_probe(root: Path) -> str:
    source = root / "Sources/Phosphor/Utilities/ArchiveSnapshot.swift"
    assert source.exists(), "ArchiveSnapshot.swift must define the stable source-copy helper"
    harness = r'''
import Foundation

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }
let source = base.appendingPathComponent("source.phosphor")
let replacement = base.appendingPathComponent("replacement.phosphor")
try Data("original".utf8).write(to: source)
let snapshot = try ArchiveSnapshot.copyRegularFile(at: source.path)
defer { try? fm.removeItem(at: snapshot.deletingLastPathComponent()) }
var snapshotInfo = stat()
var directoryInfo = stat()
_ = stat(snapshot.path, &snapshotInfo)
_ = stat(snapshot.deletingLastPathComponent().path, &directoryInfo)
print("snapshot-mode=\(String(snapshotInfo.st_mode & 0o777, radix: 8))")
print("snapshot-directory-mode=\(String(directoryInfo.st_mode & 0o777, radix: 8))")
try Data("replacement".utf8).write(to: replacement)
_ = try fm.replaceItemAt(source, withItemAt: replacement)
let snapshotted = String(data: try Data(contentsOf: snapshot), encoding: .utf8) ?? ""
print("snapshot=\(snapshotted)")

let target = base.appendingPathComponent("target.phosphor")
let link = base.appendingPathComponent("link.phosphor")
try Data("target".utf8).write(to: target)
try fm.createSymbolicLink(at: link, withDestinationURL: target)
do {
    let unexpected = try ArchiveSnapshot.copyRegularFile(at: link.path)
    try? fm.removeItem(at: unexpected.deletingLastPathComponent())
    print("symlink=accepted")
} catch {
    print("symlink=rejected")
}
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-archive-snapshot-probe-") as tmp:
        tmp_path = Path(tmp)
        harness_path = tmp_path / "main.swift"
        binary = tmp_path / "probe"
        harness_path.write_text(harness)
        compiled = subprocess.run(
            ["swiftc", str(source), str(harness_path), "-o", str(binary)],
            text=True,
            capture_output=True,
            timeout=60,
        )
        assert compiled.returncode == 0, compiled.stderr
        result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr
        return result.stdout


def test_archive_import_rejects_symlink_and_hardlink_members_before_mutation(root: Path) -> None:
    snapshot_output = _archive_snapshot_probe(root)
    assert "snapshot=original" in snapshot_output
    assert "snapshot-mode=600" in snapshot_output
    assert "snapshot-directory-mode=700" in snapshot_output
    assert "symlink=rejected" in snapshot_output

    with tempfile.TemporaryDirectory(prefix="phosphor-archive-link-members-") as tmp:
        base = Path(tmp)
        source = base / "source" / "UDID"
        source.mkdir(parents=True)
        (source / "Info.plist").write_text("info")
        (source / "Manifest.plist").write_text("manifest")
        (source / "blob").write_text("payload")

        safe_archive = base / "safe.phosphor"
        subprocess.run(
            ["tar", "-czf", str(safe_archive), "-C", str(base / "source"), "UDID"],
            check=True,
            capture_output=True,
        )

        outside = base / "outside"
        outside.write_text("outside")
        (source / "linkblob").symlink_to(outside)
        symlink_archive = base / "symlink.phosphor"
        subprocess.run(
            ["tar", "-czf", str(symlink_archive), "-C", str(base / "source"), "UDID"],
            check=True,
            capture_output=True,
        )
        (source / "linkblob").unlink()

        os.link(source / "blob", source / "hardblob")
        hardlink_archive = base / "hardlink.phosphor"
        subprocess.run(
            [
                "tar", "-czf", str(hardlink_archive), "-C", str(base / "source"),
                "UDID/Info.plist", "UDID/Manifest.plist", "UDID/blob", "UDID/hardblob",
            ],
            check=True,
            capture_output=True,
        )

        def verbose_listing(archive: Path) -> str:
            result = subprocess.run(
                ["tar", "-tvzf", str(archive)],
                env={"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                text=True,
                capture_output=True,
                timeout=30,
            )
            assert result.returncode == 0, result.stderr
            return result.stdout

        safe_listing = verbose_listing(safe_archive)
        symlink_listing = verbose_listing(symlink_archive)
        hardlink_listing = verbose_listing(hardlink_archive)
        assert any(line.startswith("l") for line in symlink_listing.splitlines()), symlink_listing
        assert any(line.startswith("h") for line in hardlink_listing.splitlines()), hardlink_listing
        assert _archive_member_listing_is_safe(root, safe_listing)
        assert not _archive_member_listing_is_safe(root, symlink_listing)
        assert not _archive_member_listing_is_safe(root, hardlink_listing)
        for unsafe_type in ("p", "c", "b"):
            assert not _archive_member_listing_is_safe(
                root,
                f"{unsafe_type}rw-r--r--  0 user group 0 Jan  1 00:00 UDID/unsafe\n",
            )

    archiver = (root / "Sources/Phosphor/Services/BackupArchiver.swift").read_text()
    archive_entries = archiver.split("private static func archiveEntries", 1)[1].split(
        "/// Strip a leading", 1
    )[0]
    assert "ArchiveMemberValidation.allEntriesAreRegularFilesOrDirectories" in archive_entries
    assert 'extraEnvironment: ["LC_ALL": "C"]' in archive_entries
    import_flow = archiver.split("static func importArchive(", 1)[1].split("// MARK: - Inspect", 1)[0]
    assert "snapshotArchive(at: archivePath)" in import_flow
    assert "archiveEntries(at: stableArchivePath)" in import_flow
    assert 'arguments: ["-xzf", stableArchivePath, "-C", destination]' in import_flow
    assert import_flow.count("archivePath") == 2, (
        "archive import must mention the user-controlled source only in its parameter and stable snapshot call"
    )
    assert import_flow.index("archiveEntries(at: stableArchivePath)") < import_flow.index("fm.createDirectory")

    inspect_flow = archiver.split("static func inspectArchive(", 1)[1].split("// MARK: - Validation", 1)[0]
    assert "snapshotArchive(at: path)" in inspect_flow
    assert "archiveEntries(at: stableArchivePath)" in inspect_flow
    assert 'arguments: ["-xzf", stableArchivePath' in inspect_flow
    assert 'arguments: ["-tvzf", stableArchivePath]' in inspect_flow
    assert 'arguments: ["-tvzf", path]' not in inspect_flow, (
        "archive inspection must not reopen the user-controlled source after snapshotting"
    )


def test_network_location_identity_and_availability_are_fail_closed(root: Path) -> None:
    output = _compile_and_run(
        root,
        r'''
import Foundation

func printState(_ label: String, _ state: BackupLocationAvailability) {
    switch state {
    case .available: print("\(label)=available")
    case .offline: print("\(label)=offline")
    case .invalid: print("\(label)=invalid")
    }
}

let remote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "remote-uuid",
    volumeName: "NAS",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let record = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: remote
)
print("relative=\(record.relativePath)")
printState("available", BackupLocationClassifier.classify(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    record: record,
    volume: remote
))
printState("missing", BackupLocationClassifier.classify(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    record: record,
    volume: nil
))
let staleLocal = BackupVolumeSnapshot(
    mountPath: "/",
    volumeUUID: "local-uuid",
    volumeName: "Macintosh HD",
    isLocal: true,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
printState("stale-local", BackupLocationClassifier.classify(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    record: record,
    volume: staleLocal
))
let wrongRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "different-uuid",
    volumeName: "NAS",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
printState("wrong-identity", BackupLocationClassifier.classify(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    record: record,
    volume: wrongRemote
))
let missingSubfolder = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "remote-uuid",
    volumeName: "NAS",
    isLocal: false,
    pathExists: false,
    isDirectory: false,
    isReadable: false,
    isWritable: false
)
printState("missing-subfolder", BackupLocationClassifier.classify(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    record: record,
    volume: missingSubfolder
))
let symlinkEscape = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "remote-uuid",
    volumeName: "NAS",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true,
    pathResolvesWithinMount: false
)
printState("symlink-escape", BackupLocationClassifier.classify(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    record: record,
    volume: symlinkEscape
))
switch BackupLocationClassifier.resolveMountedVolume(record: record, volumes: [wrongRemote]) {
case .invalid: print("wrong-mounted=invalid")
case .offline: print("wrong-mounted=offline")
case .match: print("wrong-mounted=match")
}
switch BackupLocationClassifier.resolveMountedVolume(record: record, volumes: []) {
case .invalid: print("absent-mounted=invalid")
case .offline: print("absent-mounted=offline")
case .match: print("absent-mounted=match")
}
do {
    _ = try BackupLocationRecord.capture(configuredPath: "/Volumes/USB/Backups", volume: staleLocal)
    print("local-capture=accepted")
} catch {
    print("local-capture=rejected")
}
''',
    )
    assert "relative=iPhone Backups" in output
    assert "available=available" in output
    assert "missing=offline" in output
    assert "stale-local=offline" in output
    assert "wrong-identity=invalid" in output
    assert "missing-subfolder=invalid" in output
    assert "symlink-escape=invalid" in output
    assert "wrong-mounted=invalid" in output
    assert "absent-mounted=offline" in output
    assert "local-capture=rejected" in output


def test_uuidless_network_locations_require_stable_remote_source_identity(root: Path) -> None:
    output = _compile_and_run(
        root,
        r'''
import Foundation

func state(_ volume: BackupVolumeSnapshot?, record: BackupLocationRecord) -> String {
    switch BackupLocationClassifier.classify(
        configuredPath: "/Volumes/NAS/iPhone Backups",
        record: record,
        volume: volume
    ) {
    case .available: return "available"
    case .offline: return "offline"
    case .invalid: return "invalid"
    }
}

let uuidlessRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: "//backup.example/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let record = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: uuidlessRemote
)
print("same=\(state(uuidlessRemote, record: record))")
print("stored-source-hash=\(record.volumeSourceHash ?? "nil")")

let uuidRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "first-session-uuid",
    volumeName: "NAS",
    volumeSource: "//backup.example/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let uuidRecord = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: uuidRemote
)
let reconnectedRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "second-session-uuid",
    volumeName: "NAS",
    volumeSource: "//backup.example/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
print("uuid-reconnect=\(state(reconnectedRemote, record: uuidRecord))")

let credentialedRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: "//backupuser@backup.example/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let credentialedRecord = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: credentialedRemote
)
print("redacted-source-hash=\(credentialedRecord.volumeSourceHash ?? "nil")")
print("redacted-match=\(state(uuidlessRemote, record: credentialedRecord))")

let URLCredentialedRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: "smb://backupuser:secret@backup.example/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let URLCredentialedRecord = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: URLCredentialedRemote
)
let URLCredentiallessReconnect = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: "smb://backup.example/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
print("url-redacted-source-hash=\(URLCredentialedRecord.volumeSourceHash ?? "nil")")
print("url-redacted-match=\(state(URLCredentiallessReconnect, record: URLCredentialedRecord))")

let embeddedAtRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: "//backupuser:secr@et@backup.example/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let embeddedAtRecord = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: embeddedAtRemote
)
print("embedded-at-redacted-source-hash=\(embeddedAtRecord.volumeSourceHash ?? "nil")")

let opaqueCredentialedRemote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: "backupuser:secret@backup.example:/ios",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let opaqueCredentialedRecord = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: opaqueCredentialedRemote
)
print("opaque-redacted-source-hash=\(opaqueCredentialedRecord.volumeSourceHash ?? "nil")")

let differentShare = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: "//backup.example/other",
    fileSystemType: "smbfs",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
print("different=\(state(differentShare, record: record))")

let nameOnly = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: nil,
    volumeName: "NAS",
    volumeSource: nil,
    fileSystemType: nil,
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
do {
    _ = try BackupLocationRecord.capture(
        configuredPath: "/Volumes/NAS/iPhone Backups",
        volume: nameOnly
    )
    print("name-only=accepted")
} catch {
    print("name-only=rejected")
}
''',
    )
    assert "same=available" in output
    hashes = {
        line.split("=", 1)[0]: line.split("=", 1)[1]
        for line in output.splitlines()
        if "source-hash=" in line
    }
    assert hashes, output
    assert all(len(value) == 64 and all(c in "0123456789abcdef" for c in value) for value in hashes.values())
    assert "secret" not in output and "backupuser" not in output and "backup.example" not in output
    assert "uuid-reconnect=available" in output
    assert "redacted-match=available" in output
    assert "url-redacted-match=available" in output
    assert "different=invalid" in output
    assert "name-only=rejected" in output


def test_unrecorded_external_disks_remain_local_and_network_volumes_require_designation(root: Path) -> None:
    output = _compile_and_run(
        root,
        r'''
import Foundation

let localDisk = BackupVolumeSnapshot(
    mountPath: "/Volumes/USB",
    volumeUUID: "usb-uuid",
    volumeName: "USB",
    isLocal: true,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let remote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "nas-uuid",
    volumeName: "NAS",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
print("usb=\(BackupLocationClassifier.classifyUnrecorded(configuredPath: "/Volumes/USB/Backups", volume: localDisk).rawValue)")
print("nas=\(BackupLocationClassifier.classifyUnrecorded(configuredPath: "/Volumes/NAS/Backups", volume: remote).rawValue)")
print("missing=\(BackupLocationClassifier.classifyUnrecorded(configuredPath: "/Volumes/Missing/Backups", volume: nil).rawValue)")
print("home=\(BackupLocationClassifier.classifyUnrecorded(configuredPath: "/Users/test/Backups", volume: nil).rawValue)")
''',
    )
    assert "usb=local" in output
    assert "nas=invalid" in output
    assert "missing=invalid" in output
    assert "home=local" in output


def test_network_destination_symlinks_cannot_escape_the_remote_mount(root: Path) -> None:
    output = _compile_and_run(
        root,
        r'''
import Foundation

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
let remote = base.appendingPathComponent("remote", isDirectory: true)
let local = base.appendingPathComponent("local", isDirectory: true)
let safe = remote.appendingPathComponent("safe", isDirectory: true)
let escape = remote.appendingPathComponent("escape", isDirectory: true)
try fm.createDirectory(at: safe, withIntermediateDirectories: true)
try fm.createDirectory(at: local, withIntermediateDirectories: true)
try fm.createSymbolicLink(at: escape, withDestinationURL: local)
defer { try? fm.removeItem(at: base) }

let safeResult = BackupLocationPathSafety.resolvesWithinMount(
    configuredPath: safe.path,
    mountPath: remote.path
)
let escapeResult = BackupLocationPathSafety.resolvesWithinMount(
    configuredPath: escape.path,
    mountPath: remote.path
)
print("safe=\(safeResult)")
print("escape=\(escapeResult)")
''',
    )
    assert "safe=true" in output
    assert "escape=false" in output


def test_network_schedule_policy_keeps_offline_and_invalid_destinations_due(root: Path) -> None:
    output = _compile_and_run(
        root,
        r'''
import Foundation

for status in [
    BackupLocationStatus.local,
    .available,
    .offline,
    .invalid
] {
    print("\(status.rawValue)=\(ScheduledNetworkBackupPolicy.shouldKeepScheduleDue(for: status))")
}
''',
    )
    assert "local=false" in output
    assert "available=false" in output
    assert "offline=true" in output
    assert "invalid=true" in output


def test_changing_the_backup_path_clears_a_stale_network_designation(root: Path) -> None:
    output = _compile_and_run(
        root,
        r'''
import Foundation

let remote = BackupVolumeSnapshot(
    mountPath: "/Volumes/NAS",
    volumeUUID: "remote-uuid",
    volumeName: "NAS",
    isLocal: false,
    pathExists: true,
    isDirectory: true,
    isReadable: true,
    isWritable: true
)
let record = try BackupLocationRecord.capture(
    configuredPath: "/Volumes/NAS/iPhone Backups",
    volume: remote
)
print("same=\(BackupLocationRecord.reconciled(record, configuredPath: "/Volumes/NAS/iPhone Backups") != nil)")
print("changed=\(BackupLocationRecord.reconciled(record, configuredPath: "/Users/test/Backups") == nil)")
''',
    )
    assert "same=true" in output
    assert "changed=true" in output


def test_mount_monitor_settings_and_scheduler_use_the_network_contract(root: Path) -> None:
    monitor_path = root / "Sources/Phosphor/Services/BackupLocationMonitor.swift"
    assert monitor_path.exists(), "an app-owned mount monitor must drive live network status"
    monitor = monitor_path.read_text()
    settings = (root / "Sources/Phosphor/Views/Settings/SettingsView.swift").read_text()
    app = (root / "Sources/Phosphor/App/PhosphorApp.swift").read_text()
    scheduler = (root / "Sources/Phosphor/Services/BackupScheduler.swift").read_text()
    archiver = (root / "Sources/Phosphor/Services/BackupArchiver.swift").read_text()
    manager = (root / "Sources/Phosphor/Services/BackupManager.swift").read_text()

    assert "NSWorkspace.didMountNotification" in monitor
    assert "NSWorkspace.didUnmountNotification" in monitor
    assert "BackupLocationPathSafety.resolvesWithinMount" in monitor, (
        "network destinations must resolve inside the saved remote mount"
    )
    assert "BackupLocationClassifier.resolveMountedVolume" in monitor, (
        "the monitor must distinguish an absent share from a wrong volume mounted at the saved path"
    )
    assert "Task.detached" in monitor, "dead network volume probes must not run on MainActor"
    operation_preflight = monitor.split(
        "nonisolated static func preflightForWrite(path: String)", 1
    )[1].split("nonisolated static func preflightForWrite(\n", 1)[0]
    assert "loadRecord()" in operation_preflight
    assert "reconciledRecord" not in operation_preflight, (
        "a captured old operation root must not clear a newer saved network designation"
    )
    assert "UserDefaults.didChangeNotification" not in monitor
    assert "Use as Network Location" in settings
    assert "Stop Treating as Network Location" in settings
    designation = monitor.split("func designateCurrentPath(", 1)[1].split("func clearDesignation", 1)[0]
    assert "record.matchesConfiguredPath(BackupManager.activeBackupDir)" in designation, (
        "an asynchronous designation must not persist after the user changes the configured backup path"
    )
    assert "BackupLocationDesignationError.pathChanged" in designation
    assert "backupLocationMonitor" in app
    assert "await deviceVM.refreshReadiness()" in app
    assert "if status == .available" in app
    assert "ScheduledNetworkBackupPolicy.shouldKeepScheduleDue" in scheduler
    assert "Waiting for network backup location" in scheduler
    assert "preflightForWrite" in manager
    assert "preflightForWrite" in archiver

    full_backup = manager.split("func createBackup(", 1)[1].split("private func idevicebackupArguments", 1)[0]
    incremental = manager.split("func createIncrementalBackup(", 1)[1].split("// MARK: - Restore", 1)[0]
    assert full_backup.count("BackupLocationMonitor.preflightForWrite(path: backupRoot)") >= 3, (
        "full backup must recheck the mount before preflight, primary backend launch, and fallback launch"
    )
    assert incremental.count("BackupLocationMonitor.preflightForWrite(path: backupRoot)") >= 3, (
        "incremental backup must recheck the mount before preflight, primary backend launch, and fallback launch"
    )
    assert archiver.count("BackupLocationMonitor.preflightForWrite(path: destination)") >= 3, (
        "archive import must recheck before destination creation, extraction, and post-extraction inspection/rollback"
    )
    assert "let postExtractionPreflight" in archiver
    assert archiver.index("let postExtractionPreflight") < archiver.index("if result.succeeded"), (
        "archive import must validate destination identity before either success inspection or rollback cleanup"
    )


def test_destructive_backup_operations_preflight_the_network_destination(root: Path) -> None:
    manager = (root / "Sources/Phosphor/Services/BackupManager.swift").read_text()
    view_model = (root / "Sources/Phosphor/ViewModels/BackupViewModel.swift").read_text()
    readiness = (root / "Sources/Phosphor/Views/Readiness/ReadinessCenterView.swift").read_text()

    incomplete_delete = manager.split("static func deleteIncompleteBackup(", 1)[1].split(
        "// MARK: - Backup Creation", 1
    )[0]
    regular_delete = manager.split("func deleteBackup(", 1)[1].split("var totalBackupSize", 1)[0]
    assert "await BackupLocationMonitor.preflightForWrite(path: directory)" in incomplete_delete, (
        "incomplete-backup recovery must reject an offline or mismatched network destination before Trash"
    )
    assert "await BackupLocationMonitor.preflightForWrite(path: backupRoot)" in regular_delete, (
        "normal backup deletion must reject an offline or mismatched network destination before removal"
    )
    assert "try await BackupManager.deleteIncompleteBackup" in view_model, (
        "the Backups recovery flow must await the destructive destination preflight"
    )
    assert "try await BackupManager.deleteIncompleteBackup" in readiness, (
        "the Readiness recovery flow must await the destructive destination preflight"
    )
    assert "try await backupManager.deleteBackup(backup)" in view_model, (
        "the normal delete flow must await the destructive destination preflight"
    )


def test_native_backup_service_preflights_every_active_root_backend(root: Path) -> None:
    native = (root / "Sources/Phosphor/Services/NativeBackupService.swift").read_text()
    assert "let backupRoot = BackupManager.activeBackupDir" in native, (
        "the native service must snapshot the configured root once per operation"
    )
    assert native.count("BackupLocationMonitor.preflightForWrite(path: backupRoot)") >= 3, (
        "the native service must preflight the operation root before dispatch and before each writing backend"
    )
    assert native.count("backupRoot: backupRoot,") >= 2, (
        "the snapshotted root must be passed into both native and pymobiledevice backup helpers"
    )
