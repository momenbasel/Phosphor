from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_clone_cancellation_after_backup_never_reaches_restore(root: Path) -> None:
    """A late cancel is still authoritative before the destructive restore starts."""
    service = read(root, "Sources/Phosphor/Services/DeviceCloneService.swift")
    gate = root / "Sources/Phosphor/Utilities/CloneCancellationGate.swift"

    assert gate.exists(), "clone continuation cancellation needs a production-owned gate"
    assert "private var cancellationGate = CloneCancellationGate()" in service, (
        "DeviceCloneService must own cancellation separately from BackupViewModel job state"
    )
    assert "func cancelClone()" in service, "clone cancellation must be requestable by the clone flow"
    view = read(root, "Sources/Phosphor/Views/Clone/DeviceCloneView.swift")
    assert "private func cancelClone()" in view, "the clone view must route cancellation through the clone-local gate"
    assert "cloneService.cancelClone()" in view, "the UI cancel action must request continuation cancellation"
    assert "backupVM.cancelBackup(udid: sourceUDID)" in view, "the UI cancel action must also stop the active source backup"
    assert "Button(\"Cancel\", role: .destructive)" in view, "an active clone needs a reachable cancel action"
    assert "defer { cancellationGate.reset() }" in service, (
        "every clone terminal path must reset its cancellation request"
    )

    backup_await = service.index("await backupViewModel.createBackup")
    continuation_cancel_guard = service.index("guard !cancellationGate.isCancellationRequested else")
    restore = service.index("await backupManager.restoreBackup")
    assert backup_await < continuation_cancel_guard < restore, (
        "a cancellation arriving after backup completion must stop clone continuation before restore"
    )

    probe = r'''
import Foundation

@main
struct CloneCancellationProbe {
    static func main() {
        var gate = CloneCancellationGate()
        var sourceBackupFinished = false
        var restoreStarted = false

        func continueClone() {
            guard sourceBackupFinished else { fatalError("probe must model completed source backup") }
            guard !gate.isCancellationRequested else { return }
            restoreStarted = true
        }

        sourceBackupFinished = true
        // Simulates Cancel arriving after the backup subprocess completes but before
        // the clone task resumes its restore continuation.
        gate.requestCancellation()
        continueClone()
        precondition(!restoreStarted, "late clone cancellation must prevent destination restore")

        gate.reset()
        precondition(!gate.isCancellationRequested, "terminal cleanup must not poison the next clone")
        continueClone()
        precondition(restoreStarted, "a reset gate must allow a later clone continuation")
        print("PASS")
    }
}
'''

    with tempfile.TemporaryDirectory(prefix="phosphor-clone-cancel-") as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        binary_path = temp / "clone-cancel-probe"
        probe_path.write_text(probe)
        result = subprocess.run(
            ["swiftc", str(gate), str(probe_path), "-o", str(binary_path)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "PASS"
