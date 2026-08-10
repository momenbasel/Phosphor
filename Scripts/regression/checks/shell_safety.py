from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def swift_block_after(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"unterminated Swift block after {signature}")


def test_shell_run_does_not_block_global_dispatch_workers(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = swift_block_after(src, "static func run(_ command: String")
    assert "launchManagedProcess" in body, "Shell.run should launch a session-scoped managed child"
    assert "terminateTimedOutTreeSynchronously" in body, "Shell.run should force-kill commands that ignore graceful timeout termination"
    assert "waitUntilExit()" not in body, "Shell.run must not burn a global dispatch worker in waitUntilExit()"
    assert "DispatchQueue.global" not in body, "Shell.run must not allocate a global queue worker per process"


def test_shell_run_async_does_not_block_global_dispatch_workers(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = swift_block_after(src, "static func runAsync(_ command: String")
    assert "launchManagedProcess" in body, "runAsync must launch a session-scoped managed child"
    assert "DispatchSource.makeProcessSource" in body, "runAsync should observe child exit without blocking a worker"
    assert "readabilityHandler" in body, "Shell.runAsync should collect pipe output without blocking reader workers"
    assert "waitUntilExit()" not in body, "Shell.runAsync must not block a worker in waitUntilExit()"
    assert "DispatchQueue.global" not in body, "Shell.runAsync must not allocate a global queue worker per process"


def test_shell_run_async_cancels_timeout_watchdog_on_finish(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = swift_block_after(src, "static func runAsync(_ command: String")
    assert "attachWatchdog" in body, "runAsync should hand its timeout watchdog to the state so it can be cancelled early"
    assert "pendingWatchdog?.cancel()" in src, "finish should cancel the watchdog so pipe fds are freed the moment the command completes"
    assert "state.finish(timeout: timeout, exitCode: exitCode)" in body, "runAsync must let state map an owned timeout to -2 without reading Process.terminationStatus"


def test_shell_timeouts_cannot_be_reported_as_success(root: Path) -> None:
    probe = r'''
import Foundation

actor ErrorStore {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

@main
struct TimeoutProbe {
    static func main() async {
        let command = "trap 'exit 0' TERM; while :; do sleep 1; done"

        let asyncStart = Date()
        let asyncResult = await Shell.runAsync(
            "/bin/sh",
            arguments: ["-c", command],
            timeout: 0.2
        )
        let asyncElapsed = Date().timeIntervalSince(asyncStart)

        let errors = ErrorStore()
        let streamStart = Date()
        let streamCode: Int32 = await withCheckedContinuation { continuation in
            _ = Shell.runStreaming(
                "/bin/sh",
                arguments: ["-c", command],
                timeout: 0.2,
                onOutput: { _ in },
                onError: { error in Task { await errors.append(error) } },
                completion: { continuation.resume(returning: $0) }
            )
        }
        let streamElapsed = Date().timeIntervalSince(streamStart)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let streamErrors = await errors.snapshot()

        // Negative control: a command that finishes well inside its timeout must
        // still report its own exit code. Without this, a mutation that reports
        // every command as timed out passes the assertions above.
        let fastResult = await Shell.runAsync(
            "/bin/sh",
            arguments: ["-c", "exit 3"],
            timeout: 30
        )
        let fastStreamCode: Int32 = await withCheckedContinuation { continuation in
            _ = Shell.runStreaming(
                "/bin/sh",
                arguments: ["-c", "exit 3"],
                timeout: 30,
                onOutput: { _ in },
                onError: { _ in },
                completion: { continuation.resume(returning: $0) }
            )
        }

        let asyncError = asyncResult.stderr.replacingOccurrences(of: "\n", with: " ")
        print("ASYNC|\(asyncResult.exitCode)|\(asyncElapsed)|\(asyncError)")
        print("STREAM|\(streamCode)|\(streamElapsed)|\(streamErrors.joined(separator: " "))")
        print("FAST|\(fastResult.exitCode)|0|\(fastResult.stderr.replacingOccurrences(of: "\n", with: " "))")
        print("FASTSTREAM|\(fastStreamCode)|0|")
    }
}
'''
    stub = "enum PyMobileDevice { static func available() -> Bool { false } }\n"

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        shell_copy = temp / "Shell.swift"
        shell_copy.write_text(read(root, "Sources/Phosphor/Utilities/Shell.swift"))
        (temp / "PyMobileDeviceStub.swift").write_text(stub)
        (temp / "Probe.swift").write_text(probe)
        executable = temp / "timeout-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(shell_copy), str(temp / "PyMobileDeviceStub.swift"), str(temp / "Probe.swift"), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    records = {line.split("|", 1)[0]: line.split("|", 3)[1:] for line in result.stdout.splitlines() if "|" in line}
    assert records["ASYNC"][0] == "-2", f"runAsync timeout was reported as exit {records['ASYNC'][0]}"
    assert records["STREAM"][0] == "-2", f"runStreaming timeout was reported as exit {records['STREAM'][0]}"
    assert "timed out" in records["ASYNC"][2].lower(), f"runAsync timeout should include a diagnostic: {result.stdout!r}"
    assert "timed out" in records["STREAM"][2].lower(), "runStreaming timeout should include a diagnostic"
    assert 0.1 <= float(records["ASYNC"][1]) < 2, f"runAsync should complete near its timeout: {records}"
    assert 0.1 <= float(records["STREAM"][1]) < 2, f"runStreaming should complete near its timeout: {records}"
    assert records["FAST"][0] == "3", f"a command that finished in time must keep its own exit code, got {records['FAST'][0]}"
    assert records["FASTSTREAM"][0] == "3", f"runStreaming must keep a completed command's exit code, got {records['FASTSTREAM'][0]}"
    assert "timed out" not in records["FAST"][2].lower(), "a command that finished in time must not carry a timeout diagnostic"


def test_shell_run_streaming_has_bounded_timeout_and_force_kill(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = src[src.index("static func runStreaming("):src.index("    /// Terminate a long-running managed command")]
    assert "timeout: TimeInterval?" in body, "Shell.runStreaming should let one-shot streams set a timeout"
    assert "launchManagedProcess" in body, "Shell.runStreaming should launch a managed session child"
    assert "readabilityHandler" in body, "Shell.runStreaming should stream pipe output without blocking reader workers"
    assert "terminateTimedOutTree" in body, "Shell.runStreaming should force-kill commands that ignore timeout termination"
    assert "setTimeoutTask" in body, "Shell.runStreaming should cancel timeout sleeper tasks on normal completion"
    assert "Task.isCancelled" in body, "Shell.runStreaming timeout task should stop promptly after finish cancels it"
    assert "waitUntilExit()" not in body, "Shell.runStreaming must not block a worker in waitUntilExit()"
    assert "DispatchQueue.global" not in body, "Shell.runStreaming must not allocate a global queue worker per process"


def test_backup_streaming_callers_are_timeout_bounded_and_cancelable(root: Path) -> None:
    backup = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert "streamingBackupTimeout" in backup, "backup streams should use a named timeout"
    assert "streamingRestoreTimeout" in backup, "restore streams should use a named timeout"
    assert "timeout: Self.streamingBackupTimeout" in backup, "backup subprocess streams must pass the backup timeout"
    assert "timeout: Self.streamingRestoreTimeout" in backup, "restore subprocess streams must pass the restore timeout"
    assert "activeProcess = Shell.runStreaming" in backup, "fallback streaming processes should be cancelable via activeProcess"
    assert "beginCancellableOperation(udid:" in backup, "backup/restore operations should use per-device operation IDs rather than one shared cancellation boolean"
    assert "cancelledOperationIDs.insert(activeOperationID)" in backup, "cancelBackup should mark the active operation canceled before killing the child"
    assert "operationWasCancelled(operationID)" in backup, "cancelled primary streams should not fall through into fallback backups"
    assert "lastOperationWasCancelled" in backup, "cancellation should be exposed separately from lastError/backup failures"
    assert "if operationCoordinator.activeOperationID == id" in swift_block_after(backup, "private func markOperationCancelled"), "stale cancelled operations should not overwrite current operation UI state"
    assert "backupCancelled" not in backup, "backup/restore cancellation must not use one shared mutable boolean"
    assert "lastError = nil" in swift_block_after(backup, "func cancelBackup()"), "cancelBackup should not report user cancellation as an error"
    assert "Shell.terminate(activeProcess)" in backup, "cancelBackup should escalate termination for stuck subprocesses"

    backup_vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert "manager.lastOperationWasCancelled" in backup_vm, "each device activity should treat its own cancellation separately from failure"
    assert "private var backupManagers: [String: BackupManager]" in backup_vm, "concurrent devices need independent process and completion owners"
    assert "updateBackupProgress(udid: udid" in backup_vm, "backup progress updates must remain scoped to the originating device"

    time_machine = read(root, "Sources/Phosphor/Views/Backup/BackupTimeMachineView.swift")
    assert "lastOperationWasCancelled" in time_machine, "restore UI should not show a generic failure alert after cancellation"

    diagnostics = read(root, "Sources/Phosphor/Services/DiagnosticsManager.swift")
    assert "syslogStreamID" in diagnostics, "syslog streams should use an identity token so stopped/stale streams cannot update UI"
    assert "let primaryProcess = PyMobileDevice.startSyslog" in diagnostics, "primary syslog launch should be assigned locally before mutating syslogProcess"
    assert "if let primaryProcess" in diagnostics, "primary syslog process should only be stored after synchronous launch-failure completions finish"
    assert "syslogProcess == nil" in diagnostics, "fallback launch should not overwrite or duplicate an already-installed process"
    assert "if exitCode != 0, self.isStreamingSyslog" in diagnostics, "runtime pymobiledevice3 syslog failures should fall back while the stream is current"
    assert "self.startSyslogFallback(udid: udid, streamID: streamID)" in diagnostics, "primary syslog completion should route runtime failures to fallback"
    assert "guard syslogStreamID == streamID, isStreamingSyslog else { return }" in diagnostics, "fallback syslog should not start after Stop or a newer stream"
    assert "guard let self, self.syslogStreamID == streamID else { return }" in diagnostics, "stale syslog output/completions should be ignored"
    assert "syslogStreamID = nil" in swift_block_after(diagnostics, "func stopSyslog()"), "stopSyslog should invalidate stream identity before termination completions fire"
    assert "syslogProcess = Shell.runStreaming" in diagnostics, "syslog fallback should be stoppable via syslogProcess"
    assert "Shell.terminate(syslogProcess)" in diagnostics, "stopSyslog should escalate termination for stuck syslog children"


def test_backup_ownership_blocks_same_device_but_allows_different_devices(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    coordinator_path = root / "Sources/Phosphor/Services/BackupOperationCoordinator.swift"
    assert coordinator_path.exists(), "backup ownership should be extracted for behavioral testing"
    coordinator = coordinator_path.read_text()
    assert "struct BackupOperationRegistry" in coordinator
    # Per-device ownership (#60) and the backup/comparison reader-writer gate
    # (#70) are separate concerns that both shipped a type called
    # BackupOperationCoordinator. The gate kept the name because BackupManager
    # calls it through a shared singleton; per-device ownership is
    # BackupDeviceCoordinator.
    assert "struct BackupDeviceCoordinator" in coordinator
    assert "final class BackupOperationCoordinator" in coordinator
    assert "private static var operationRegistry" in manager, "all manager instances must share per-device ownership"
    assert manager.count("beginCancellableOperation(udid:") >= 4, "full, incremental, restore, and the helper must use device ownership"

    probe = r'''
import Foundation

@main
struct OperationOwnershipProbe {
    static func main() {
        var registry = BackupOperationRegistry()
        var phoneManager = BackupDeviceCoordinator()
        var duplicatePhoneManager = BackupDeviceCoordinator()
        var tabletManager = BackupDeviceCoordinator()
        var thirdDeviceManager = BackupDeviceCoordinator()

        let phoneID = UUID()
        let duplicateID = UUID()
        let tabletID = UUID()
        let replacementID = UUID()
        let thirdDeviceID = UUID()

        precondition(phoneManager.begin(udid: "phone", operationID: phoneID, registry: &registry) == phoneID)
        precondition(duplicatePhoneManager.begin(udid: "phone", operationID: duplicateID, registry: &registry) == nil)
        precondition(tabletManager.begin(udid: "tablet", operationID: tabletID, registry: &registry) == tabletID)
        precondition(thirdDeviceManager.begin(udid: "watch", operationID: thirdDeviceID, registry: &registry) == nil)

        // Cancellation does not release ownership until the subprocess completion
        // finishes with the matching operation identity.
        precondition(duplicatePhoneManager.begin(udid: "phone", operationID: replacementID, registry: &registry) == nil)
        precondition(phoneManager.finish(operationID: phoneID, registry: &registry))
        precondition(thirdDeviceManager.begin(udid: "watch", operationID: thirdDeviceID, registry: &registry) == thirdDeviceID)
        precondition(thirdDeviceManager.finish(operationID: thirdDeviceID, registry: &registry))
        precondition(phoneManager.begin(udid: "phone", operationID: replacementID, registry: &registry) == replacementID)

        // A stale completion cannot release the replacement operation.
        precondition(!phoneManager.finish(operationID: phoneID, registry: &registry))
        precondition(duplicatePhoneManager.begin(udid: "phone", operationID: duplicateID, registry: &registry) == nil)
        precondition(phoneManager.finish(operationID: replacementID, registry: &registry))
        precondition(tabletManager.finish(operationID: tabletID, registry: &registry))
        print("PASS")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-device-ownership-") as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        binary_path = temp / "operation-ownership-probe"
        probe_path.write_text(probe)
        result = subprocess.run(
            ["swiftc", "-parse-as-library", str(coordinator_path), str(probe_path), "-o", str(binary_path)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "PASS"


def test_restore_captures_target_and_uses_backup_parent_with_source_udid(root: Path) -> None:
    time_machine = read(root, "Sources/Phosphor/Views/Backup/BackupTimeMachineView.swift")
    assert "struct RestoreRequest" in time_machine, "restore confirmation should capture one backup and target device"
    assert "@State private var pendingRestore: RestoreRequest?" in time_machine, "restore alert should be driven by one item-scoped request"
    assert "pendingRestore = RestoreRequest(backup: backup, targetUDID: target.id" in time_machine, "restore target must be captured when the button is clicked"
    assert "performRestore(request)" in time_machine, "confirmation must execute the captured request"
    assert "showRestoreConfirm" not in time_machine, "one Boolean shared by every backup card can confirm the wrong snapshot"

    backup = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert "func restoreBackup(\n        backup: BackupInfo,\n        targetUDID: String" in backup, "restore service should accept typed source-backup metadata and an explicit target"
    assert "deletingLastPathComponent" in swift_block_after(backup, "func restoreBackup("), "restore backends need the directory containing the source-UDID folder"
    restore_body = swift_block_after(backup, "func restoreBackup(")
    # The source has to be the folder name on disk. backup.udid is Info.plist's
    # "Target Identifier", which differs from the directory name for timestamped
    # and imported backups, and both backends open backupRoot/<source>.
    assert "lastPathComponent" in restore_body, "restore source must be the on-disk backup folder name, not the parsed Info.plist UDID"
    assert "sourceUDID: sourceIdentifier" in restore_body, "pymobiledevice restore must receive the folder-derived source identifier"
    assert "sourceUDID: backup.udid" not in restore_body, "backup.udid is the Target Identifier and can name a different folder than the one the user picked"
    assert '"-s", backup.udid' not in restore_body, "the idevicebackup2 source must be the folder name too, not the Target Identifier"
    assert "sourceIdentifier.isEmpty" in restore_body, "an empty source identifier must abort instead of silently restoring the target onto itself"
    assert '"-u", targetUDID, "-s", sourceIdentifier, "restore", "--system", "--reboot", backupRoot' in backup, "idevicebackup2 options must precede restore, and --reboot must match the pymobiledevice3 path and the confirmation dialog"

    py = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    restore = swift_block_after(py, "static func restore(")
    assert "sourceUDID: String?" in restore, "pymobiledevice restore should accept a source backup UDID"
    # An empty --source makes pymobiledevice3 fall back to the target's own UDID.
    assert 'if let sourceUDID, !sourceUDID.isEmpty { args += ["--source", sourceUDID] }' in restore, "an empty source must omit --source rather than silently mean the target device"

    clone = read(root, "Sources/Phosphor/Services/DeviceCloneService.swift")
    assert "backup: latestBackup" in clone and "targetUDID: destinationUDID" in clone, "clone restore must keep source backup and destination device distinct"
    assert "previousFingerprints" in clone, "clone must capture a pre-backup snapshot before choosing restore input"
    assert "freshSourceBackups" in clone, "clone must reject unchanged stale backups even when their directory is canonical"
    assert "backupFreshnessDate" in clone, "clone must select the freshest verified changed backup when multiple source snapshots exist"


def test_cancellation_token_model_prevents_cancelled_primary_from_starting_fallback(root: Path) -> None:
    del root
    active_operation_id: str | None = None
    cancelled_operation_ids: set[str] = set()
    fallback_started: list[str] = []
    progress_text = ""

    def begin(operation_id: str) -> str:
        nonlocal active_operation_id
        active_operation_id = operation_id
        return operation_id

    def cancel_current() -> None:
        if active_operation_id is not None:
            cancelled_operation_ids.add(active_operation_id)

    def mark_cancelled(operation_id: str) -> None:
        nonlocal active_operation_id, progress_text
        if active_operation_id == operation_id:
            progress_text = "Cancelled"
            active_operation_id = None
        cancelled_operation_ids.discard(operation_id)

    def primary_completed(operation_id: str, exit_code: int) -> None:
        if operation_id in cancelled_operation_ids:
            mark_cancelled(operation_id)
            return
        if exit_code != 0:
            fallback_started.append(operation_id)

    first = begin("first")
    cancel_current()
    second = begin("second")
    primary_completed(first, exit_code=1)
    primary_completed(second, exit_code=0)

    assert fallback_started == [], "a cancelled primary must not start fallback after a newer operation begins"
    assert cancelled_operation_ids == set(), "cancelled operation IDs should be cleaned up when their completion arrives"
    assert progress_text == "", "stale cancelled completions must not overwrite the current operation's UI"


def test_no_crash_only_swift_shortcuts(root: Path) -> None:
    offenders: list[str] = []
    for path in (root / "Sources").rglob("*.swift"):
        text = path.read_text(errors="ignore")
        for lineno, line in enumerate(text.splitlines(), start=1):
            if "try!" in line or "as!" in line or "fatalError(" in line or "preconditionFailure(" in line:
                offenders.append(f"{path.relative_to(root)}:{lineno}: {line.strip()}")
    assert not offenders, "Avoid crash-only Swift shortcuts:\n" + "\n".join(offenders)
