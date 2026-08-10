from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_collision_safe_publisher_preserves_existing_files_and_all_outputs(root: Path) -> None:
    helper = root / "Sources/Phosphor/Utilities/CollisionSafeFilePublisher.swift"
    assert helper.exists(), "collision-safe publication helper must exist"

    probe = r'''
import Foundation

struct ProbeFailure: Error {}

@main
struct Probe {
    static func main() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phosphor-music-publisher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("Track.m4a")
        try Data("existing".utf8).write(to: existing)

        let first = try CollisionSafeFilePublisher.publish(preferredFilename: "Track.m4a", in: directory) { staging in
            try Data("one".utf8).write(to: staging)
        }
        let second = try CollisionSafeFilePublisher.publish(preferredFilename: "Track.m4a", in: directory) { staging in
            try Data("two".utf8).write(to: staging)
        }
        let freshDestination = directory.appendingPathComponent("Fresh.m4a")
        var visibleBeforeWriterFinished = false
        let fresh = try CollisionSafeFilePublisher.publish(preferredFilename: "Fresh.m4a", in: directory) { staging in
            visibleBeforeWriterFinished = FileManager.default.fileExists(atPath: freshDestination.path)
            try Data("fresh".utf8).write(to: staging)
        }
        do {
            _ = try CollisionSafeFilePublisher.publish(preferredFilename: "Track.m4a", in: directory) { _ in
                throw ProbeFailure()
            }
        } catch {}

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let contents = try names.map { name in
            String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)), as: UTF8.self)
        }
        print("NAMES|" + names.joined(separator: ","))
        print("CONTENTS|" + contents.sorted().joined(separator: ","))
        print("RETURNED|\(first.lastPathComponent)|\(second.lastPathComponent)")
        print("ATOMIC|\(visibleBeforeWriterFinished)|\(fresh.lastPathComponent)")

        let cancelFinal = directory.appendingPathComponent("Cancelled.m4a")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try CollisionSafeFilePublisher.publish(preferredFilename: "Cancelled.m4a", in: directory) { staging in
                try Data("partial".utf8).write(to: staging)
                started.signal()
                release.wait()
            }
        }
        started.wait()
        task.cancel()
        release.signal()
        _ = try? await task.value
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".phosphor-") }
        print("CANCEL|\(FileManager.default.fileExists(atPath: cancelFinal.path))|\(leftovers.count)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "publisher-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(helper), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "NAMES|Fresh.m4a,Track (2).m4a,Track (3).m4a,Track.m4a" in result.stdout, result.stdout
    assert "CONTENTS|existing,fresh,one,two" in result.stdout, result.stdout
    assert "RETURNED|Track (2).m4a|Track (3).m4a" in result.stdout, result.stdout
    assert "ATOMIC|false|Fresh.m4a" in result.stdout, "final name must stay absent until the writer succeeds"
    assert "CANCEL|false|0" in result.stdout, "cancelled copies must leave neither a final file nor staging data"


def test_music_extraction_uses_collision_safe_atomic_publication(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/MusicTransferManager.swift")
    view = read(root, "Sources/Phosphor/Views/Music/MusicView.swift")
    helper = read(root, "Sources/Phosphor/Utilities/CollisionSafeFilePublisher.swift")
    assert "CollisionSafeFilePublisher.publish" in manager
    assert "try manifest.extractFile(entry, to: staging.path)" in manager
    assert "Task.checkCancellation()" in manager
    assert "lastError = nil" in manager, "a successful retry must clear an earlier extraction error"
    assert "catch {}" not in manager, "track extraction failures must not be swallowed"
    assert "appendingPathComponent(track.filename)" not in manager, "same-named tracks must not target the same path"
    assert "Task.detached" in manager and "withTaskCancellationHandler" in manager
    assert "try Task.checkCancellation()" in manager, "cancellation during a copy must prevent final publication"
    assert "renamex_np" in helper and "RENAME_EXCL" in helper
    # renamex_np is APFS/HFS+ only; exFAT, MS-DOS and SMB return ENOTSUP, which
    # is the normal case for extracting to a USB stick or NAS share. The
    # O_CREAT|O_EXCL reservation is the fallback for exactly those volumes, so
    # it may appear - but only behind that errno check, never as the primary
    # path, which would expose a zero-byte final name.
    assert "renamex_np" in helper, "the fast path must stay an atomic exclusive rename"
    assert "code == ENOTSUP" in helper, "a filesystem without renamex_np must fall back, not fail the extract"
    assert "extractionTask" in view and ".cancel()" in view
    assert "Music Extraction" in view and "extracted" in view
