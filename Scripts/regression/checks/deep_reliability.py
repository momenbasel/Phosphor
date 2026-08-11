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
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"unterminated Swift block after {signature}")


def test_archive_export_uses_same_volume_staging_and_atomic_publish(root: Path) -> None:
    source = read(root, "Sources/Phosphor/Services/BackupArchiver.swift")
    body = swift_block_after(source, "static func createArchive(")
    assert "stagingArchivePath" in body, "archive export must create a unique same-directory staging path"
    assert "UUID().uuidString" in body, "archive staging names must be collision-safe"
    assert '"-czf", stagingArchivePath' in body, "tar must write staging, never the published archive path"
    assert "replaceItemAt" in body, "an existing archive must be atomically replaced only after tar succeeds"
    assert "defer" in body and "removeItem(atPath: stagingArchivePath)" in body, "failed or cancelled staging output must be cleaned up"
    assert "removeItem(atPath: archivePath)" not in body, "a failed export must preserve the previous archive"


def test_pymobiledevice_cache_is_synchronized_and_resettable(root: Path) -> None:
    source = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert "private static let cacheLock = NSLock()" in source, "cached binary path requires a synchronization lock"
    find = swift_block_after(source, "private static func findBinary()")
    reset = swift_block_after(source, "static func resetBinaryCache()")
    assert "cacheLock.lock()" in find and "cacheLock.unlock()" in find, "cache access must be serialized"
    assert "cacheLock.lock()" in reset and "cachedBinaryPath = nil" in reset, "reset must safely invalidate the cache"
    build = swift_block_after(source, "private static func buildCommand(")
    assert "isDirectBinary(binary)" in build, "command construction must classify its immutable resolved path"
    assert "usesDirectBinary" not in source, "a second cache read can race reset and change a resolved command's invocation mode"


def test_background_unlock_does_not_return_a_decryptor_across_actor_boundary(root: Path) -> None:
    source = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    body = swift_block_after(source, "func submitUnlock(password: String, remember: Bool) async")
    assert "Task.detached(priority: .userInitiated) { () throws -> Void in" in body, "detached unlock must explicitly return Void"
    assert "_ = try BackupUnlockStore.shared.unlock" in body, "the non-Sendable decryptor must remain inside the detached task"


def test_password_management_fails_closed_instead_of_using_pymobiledevice_argv(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    py = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    encryption = swift_block_after(manager, "private func setBackupEncryption")
    change = swift_block_after(manager, "func changeEncryptionPassword")
    assert "PyMobileDevice.setEncryption" not in encryption, "encryption fallback must fail closed rather than pass a password in argv"
    assert "PyMobileDevice.changeEncryptionPassword" not in change, "password-change fallback must fail closed rather than pass passwords in argv"
    assert "setEncryption(enabled:" not in py, "pymobiledevice argv password helper must not remain callable"
    assert "changeEncryptionPassword(oldPassword:" not in py, "pymobiledevice argv password helper must not remain callable"


def test_flattened_photo_exports_choose_deterministic_collision_safe_names(root: Path) -> None:
    source = read(root, "Sources/Phosphor/Services/PhotoExtractor.swift")
    assert "FlatPhotoExportReservation.reserve" in source, "flattened photo exports need an atomic destination reservation"
    assert "stableID: item.id" in source, "collision names must be deterministic from the backup file identity"
    assert "reservation.stagingURL" in source and "flatReservation?.publish()" in source, "flat exports must stage privately and publish only after extraction succeeds"


def test_flat_photo_reservations_atomically_publish_parallel_exports(root: Path) -> None:
    """Parallel flattened exports must never select or publish the same output."""
    probe = r'''
import Foundation

@main
struct FlatPhotoProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let count = 24
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "flat-photo-export", attributes: .concurrent)
        let lock = NSLock()
        var failures: [String] = []

        for index in 0..<count {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let reservation = try FlatPhotoExportReservation.reserve(
                        filename: "IMG_0001.JPG",
                        stableID: "backup-file-\(index)",
                        root: root
                    )
                    try Data("payload-\(index)".utf8).write(to: reservation.stagingURL)
                    try reservation.publish()
                } catch {
                    lock.lock()
                    failures.append(error.localizedDescription)
                    lock.unlock()
                }
            }
        }
        group.wait()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.contains(".phosphor-partial-") }
        let payloads = Set(try files.map { try String(contentsOf: $0) })
        print("RESULT|\(failures.count)|\(files.count)|\(payloads.count)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "flat-photo-probe"
        compile_result = subprocess.run(
            [
                "swiftc",
                "-parse-as-library",
                str(root / "Sources/Phosphor/Utilities/FlatPhotoExportReservation.swift"),
                str(probe_path),
                "-o",
                str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        output_root = temp / "exports"
        output_root.mkdir()
        result = subprocess.run([str(executable), str(output_root)], capture_output=True, text=True, timeout=20)

    assert result.returncode == 0, result.stderr
    assert "RESULT|0|24|24" in result.stdout, result.stdout


def test_shell_process_group_catches_a_descendant_that_forks_after_timeout(root: Path) -> None:
    """A TERM-ignoring child must not outlive a timed-out leader by late-forking."""
    probe = r'''
import Foundation

@main
struct LateForkProbe {
    static func main() async {
        let marker = CommandLine.arguments[1]
        let command = """
        trap 'exit 0' TERM
        (trap '' TERM; sleep 0.35; /bin/sh -c 'trap "" TERM; echo $$ > "\(marker)"; while :; do :; done' &) &
        while :; do :; done
        """
        let result = await Shell.runAsync("/bin/sh", arguments: ["-c", command], timeout: 0.1)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let childPID = (try? String(contentsOfFile: marker))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let childStillExists = childPID.map { Darwin.kill($0, 0) == 0 || errno == EPERM } ?? false
        print("RESULT|\(result.exitCode)|\(childStillExists)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        (temp / "Probe.swift").write_text(probe)
        (temp / "PyMobileDeviceStub.swift").write_text("enum PyMobileDevice { static func available() -> Bool { false } }\n")
        executable = temp / "late-fork-probe"
        compile_result = subprocess.run(
            [
                "swiftc", "-parse-as-library",
                str(root / "Sources/Phosphor/Utilities/Shell.swift"),
                str(temp / "PyMobileDeviceStub.swift"),
                str(temp / "Probe.swift"),
                "-o", str(executable),
            ],
            capture_output=True, text=True, timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(temp / "escaped")], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "RESULT|-2|false" in result.stdout, result.stdout


def test_shell_terminates_and_confirms_full_descendant_tree_cleanup(root: Path) -> None:
    source = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    assert "POSIX_SPAWN_SETSID" in source, "Shell must create a dedicated session before a child can fork"
    assert "terminateTimedOutTree" in source, "all timeout paths must use one process-tree terminator"
    assert "SIGTERM" in source and "SIGKILL" in source, "tree termination must escalate from graceful to forced shutdown"
    assert "waitForProcessTreeCleanup" in source, "Shell must confirm descendant cleanup before reporting timeout completion"
    assert "static func terminate(_ process: ManagedProcess)" in source, "explicit cancellation must terminate a managed process tree"


def test_shell_retains_process_group_after_stream_leader_is_reaped(root: Path) -> None:
    """Quit-time cancellation must still kill a child after its leader was reaped."""
    probe = r'''
import Foundation
import Darwin

@main
struct ReapedLeaderProbe {
    static func main() async {
        let marker = CommandLine.arguments[1]
        let script = """
        import os, signal, time
        child = os.fork()
        if child:
            os._exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(\"\(marker)\", \"w\") as handle:
            handle.write(str(os.getpid()))
            handle.flush()
        while True:
            time.sleep(0.05)
        """
        guard let process = Shell.runStreaming(
            "/usr/bin/python3",
            arguments: ["-c", script],
            onOutput: { _ in },
            completion: { _ in }
        ) else {
            print("RESULT|launch-failed")
            return
        }

        var childPID: pid_t?
        for _ in 0..<100 {
            if let raw = try? String(contentsOfFile: marker),
               let parsed = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = parsed
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // The DispatchSource exit handler has time to reap the session leader.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await Shell.terminateAndWait(process)
        let childStillExists = childPID.map { Darwin.kill($0, 0) == 0 || errno == EPERM } ?? true
        print("RESULT|\(childStillExists)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        (temp / "Probe.swift").write_text(probe)
        (temp / "PyMobileDeviceStub.swift").write_text("enum PyMobileDevice { static func available() -> Bool { false } }\n")
        executable = temp / "reaped-leader-probe"
        compile_result = subprocess.run(
            [
                "swiftc", "-parse-as-library",
                str(root / "Sources/Phosphor/Utilities/Shell.swift"),
                str(temp / "PyMobileDeviceStub.swift"),
                str(temp / "Probe.swift"),
                "-o", str(executable),
            ],
            capture_output=True, text=True, timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(temp / "child-pid")], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "RESULT|false" in result.stdout, result.stdout
