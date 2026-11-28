from __future__ import annotations

import sqlite3
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_manifest_integrity_report_is_wired(root: Path) -> None:
    manifest = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    manager = (
        read(root, "Sources/Phosphor/Services/BackupManager.swift")
        + "\n"
        + read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    )
    for token in [
        "struct IntegrityReport",
        "func integrityReport(blobSampleLimit:",
        "PRAGMA integrity_check",
        "case degraded",
        "case corrupt",
        "case unreadable",
    ]:
        assert token in manifest, f"manifest integrity check missing {token}"
    assert "WHERE flags = 1 LIMIT" in manifest, "blob cross-check must skip directory rows"
    assert "Snapshot/" in manifest, "interrupted backups keep blobs under Snapshot/"
    assert "static func backupIntegrity(for udid:" in manager, "callers need one entry point"


def _make_manifest(path: Path, rows: int) -> None:
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT, flags INT)")
    conn.executemany(
        "INSERT INTO Files VALUES (?, 'AppDomain-com.x', ?, 1)",
        [(f"{i:040x}", f"file-{i}") for i in range(rows)],
    )
    conn.commit()
    conn.close()


def test_integrity_check_detects_healthy_and_truncated_manifests(root: Path) -> None:
    """The SQL the Swift check relies on, exercised against real SQLite files."""
    import tempfile

    def verdict(db: Path) -> list[str]:
        """Flatten integrity_check output. Severely damaged files make SQLite
        raise instead of returning rows; both mean "not ok"."""
        try:
            rows = sqlite3.connect(db).execute("PRAGMA integrity_check").fetchall()
        except sqlite3.DatabaseError as exc:
            return [str(exc)]
        return [row[0] for row in rows]

    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)

        good = base / "good.db"
        _make_manifest(good, 64)
        assert verdict(good) == ["ok"]

        # Zero rows must still be one "ok" row, not an empty result the caller
        # would misread as unreadable.
        empty = base / "empty.db"
        _make_manifest(empty, 0)
        assert verdict(empty) == ["ok"]

        # Truncating the file mid-page is what an interrupted backup leaves.
        corrupt = base / "corrupt.db"
        _make_manifest(corrupt, 512)
        blob = corrupt.read_bytes()
        corrupt.write_bytes(blob[: len(blob) // 3])
        flat = verdict(corrupt)
        assert flat != ["ok"], "truncated manifest must not report ok"


def test_blob_sampling_is_bounded(root: Path) -> None:
    """A 200k-row backup must not cost 200k stats on every discovery pass."""
    manifest = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    assert "blobSampleLimit: Int = 2_000" in manifest, "blob cross-check must stay bounded"
    assert "min(blobSampleLimit, total)" in manifest, "sample must never exceed row count"
