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


def test_preview_pane_routes_manifest_io_through_actor_and_cancels_stale_loads(root: Path) -> None:
    """The inspector must never touch a raw manifest (it would race the size
    resolution passes), must parse plists/SQLite off the main actor, and must
    live inside .task(id:) so a selection change cancels the previous load
    before a stale result can be applied."""
    pane = read(root, "Sources/Phosphor/Views/Backup/FilePreviewPane.swift")
    assert "let store: ManifestQueryStore" in pane, "preview I/O must go through the serialized query store"
    assert "let manifest: BackupManifest" not in pane, "the pane must not hold a raw manifest"
    assert "Task.detached" not in pane, "preview loads must stay inside .task(id:) so selection changes cancel them"
    assert ".task(id: entry.id)" in pane, "preview loads must be keyed to the selected entry"
    assert "store.readablePath(for: entry)" in pane, "path materialization/decryption must be actor-serialized"
    assert "store.extractFile(" in pane, "extraction must be actor-serialized"
    assert "static func parsePlist" in pane and "static func loadSQLitePreview" in pane, (
        "plist and SQLite parsing must run in nonisolated helpers off the main actor"
    )
    assert pane.count("Task.isCancelled") + pane.count("Task.checkCancellation") >= 3, (
        "every preview state application must re-check cancellation first"
    )

    browser = read(root, "Sources/Phosphor/Views/Backup/BackupBrowserView.swift")
    assert "FilePreviewPane(entry: selection, store: store)" in browser, (
        "the browser must hand the pane the query store, not a manifest"
    )


def test_home_screen_loads_confine_manifest_and_guard_stale_publishes(root: Path) -> None:
    """Each home-screen load owns a private manifest confined to one background
    task (web-clip reads included), and a superseded load must never publish
    onto the state of the backup that replaced it."""
    vm = read(root, "Sources/Phosphor/ViewModels/HomeScreenViewModel.swift")
    assert "loadWebClipIconData" in vm, "web-clip bytes must be read inside the load task that owns the manifest"
    assert vm.count("loadGeneration == generation") >= 3, (
        "every published write must be guarded by the load generation token"
    )
    assert "loadTask?.cancel()" in vm, "switching backups must cancel the in-flight load"


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
