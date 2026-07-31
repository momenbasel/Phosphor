from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_lazy_manifest_size_queries_do_not_eager_stat(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    for signature in ["func files(inDomain", "func search(_ query"]:
        start = src.index(signature)
        end = src.index("    ///", start + 1)
        body = src[start:end]
        assert "attributesOfItem" not in body, f"{signature} must not stat files eagerly"
        assert "SELECT fileID, domain, relativePath, flags" in body, f"{signature} should query metadata only"

    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    # Sizes resolve progressively through the actor store in cancellable chunks,
    # never synchronously on the main actor inside browseDomain/searchBackup.
    assert "store.resolveSizes(for: " in vm, "size resolution should go through the query store"
    assert "Task.checkCancellation()" in vm, "chunked size resolution should observe cancellation"
    assert "manifest.resolvingSizes(for: try manifest.files(inDomain: domain))" not in vm, "browseDomain must not synchronously resolve all sizes on the main actor"
    assert "manifest.resolvingSizes(for: try manifest.search(query))" not in vm, "searchBackup must not synchronously resolve all sizes on the main actor"


def test_manifest_open_preflights_encrypted_and_missing_backups(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    assert "case manifestMissing" in src, "missing Manifest.db should have a typed user-facing error"
    assert "case backupEncrypted" in src, "encrypted backup should have a typed user-facing error"
    assert "PlistParser.parseManifest(backupPath)?.isEncrypted" in src, "Manifest.plist encryption should be checked before sqlite open"
    assert "SQLite format 3" in src, "Manifest.db header should be preflighted before sqlite open"
    assert "case manifestUnreadable" in src, "unreadable Manifest.db should preserve the underlying error"
    # An encrypted backup is only an error when it has not been unlocked this
    # session. Once unlocked, the manifest serves plaintext and every consumer
    # (Messages, Photos, Apps, Notes, Contacts, Calendar, Safari, Health, WhatsApp)
    # keeps working without its own password prompt.
    assert "BackupUnlockStore.shared.decryptor(for: backupPath)" in src, "an unlocked backup must open instead of throwing backupEncrypted"
    assert "throw ManifestError.backupEncrypted" in src, "a locked backup must still surface the typed encrypted error"
    assert "func fileData(for entry: FileEntry) throws -> Data" in src, "blob reads must go through a decrypting accessor"
    assert "func readablePath(for entry: FileEntry) throws -> String" in src, "path-based readers need a decrypted copy, not the raw ciphertext blob"
