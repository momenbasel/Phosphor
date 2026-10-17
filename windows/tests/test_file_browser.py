import asyncio
import base64
import hashlib
import os
import posixpath
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
import file_browser
from file_browser import FileBrowser, checked_local, filename, page_rows, virtual_path

UDID = "00008030-001234567890ABCD"


@pytest.mark.parametrize(
    "value", ["../outside", "/a/../b", "/a\\b", "/a/./b", "/a\x00b", "C:/outside"]
)
def test_virtual_scope_rejects_traversal(value):
    with pytest.raises(ValueError):
        virtual_path(value)


@pytest.mark.parametrize(
    "value", ["../file", "CON.txt", "a:b", "a\\b", "a/file", "file.", "", "nul"]
)
def test_names_reject_windows_aliases(value):
    with pytest.raises(ValueError):
        filename(value)


def test_local_root_tokens_filters_and_copy_collision(fixture_backup, tmp_path):
    store, _, _ = fixture_backup
    browser = FileBrowser(store, tmp_path / "profile")
    local = tmp_path / "local"
    local.mkdir()
    (local / "large.txt").write_bytes(b"123456789")
    (local / "small.txt").write_bytes(b"1")
    (local / "Folder").mkdir()
    token = browser.register_local(local)["root"]
    with pytest.raises(ValueError, match="Choose this folder"):
        browser.list(source="local", root="invalid")
    rows = browser.list(source="local", root=token, sort="size", direction="desc")["rows"]
    assert [r["name"] for r in rows] == ["Folder", "large.txt", "small.txt"]
    assert browser.list(source="local", root=token, query="SMALL", kind="file")["total"] == 1
    assert browser.preview(source="local", root=token, path="/small.txt")["text"] == "1"
    output = tmp_path / "download"
    output.mkdir()
    browser.operation(
        "download", source="local", root=token, paths=["/small.txt"], localPath=output
    )
    assert (output / "small.txt").read_bytes() == b"1"
    with pytest.raises(ValueError, match="already exists"):
        browser.operation(
            "download", source="local", root=token, paths=["/small.txt"], localPath=output
        )
    assert not list(output.glob("*.partial"))
    with pytest.raises(ValueError):
        browser.operation("rename", source="local", root=token, paths=["/"], name="outside")
    browser.operation(
        "rename", source="local", root=token, paths=["/small.txt"], name="renamed.txt"
    )
    assert (local / "renamed.txt").exists()
    browser.operation("mkdir", source="local", root=token, path="/", name="New folder")
    assert (local / "New folder").is_dir()


def test_local_delete_is_confirmed_and_scoped(fixture_backup, tmp_path, monkeypatch):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    root = tmp_path / "local"
    root.mkdir()
    (root / "item.txt").write_text("keep")
    token = browser.register_local(root)["root"]
    targets = []
    monkeypatch.setattr(file_browser, "recycle", lambda target: targets.append(target))
    with pytest.raises(ValueError, match="Confirm"):
        browser.operation("trash", source="local", root=token, paths=["/item.txt"])
    browser.operation("trash", source="local", root=token, paths=["/item.txt"], confirmed=True)
    assert targets == [root / "item.txt"]
    with pytest.raises(ValueError):
        browser.operation("trash", source="local", root=token, paths=["/"], confirmed=True)
    assert targets == [root / "item.txt"]


def test_local_links_blocked_without_reading_target(fixture_backup, tmp_path):
    root = tmp_path / "local"
    outside = tmp_path / "outside"
    root.mkdir()
    outside.mkdir()
    (outside / "private.txt").write_text("private")
    try:
        (root / "link").symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("Windows symlinks need privileges")
    with pytest.raises(ValueError):
        checked_local(root, "/link/private.txt")
    with pytest.raises(ValueError):
        checked_local(root / "link", "/")


def test_backup_tree_preview_folder_export_and_immutability(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    browser = FileBrowser(store, tmp_path / "profile")
    before = hashlib.sha256((Path(backup) / "Manifest.db").read_bytes()).digest()
    assert browser.list(source="backup", backup=backup)["capabilities"]["readOnly"]
    domains = browser.list(source="backup", backup=backup)["rows"]
    assert any(r["name"] == "CameraRollDomain" for r in domains)
    assert (
        browser.list(source="backup", backup=backup, path="/CameraRollDomain")["rows"][0]["name"]
        == "Media"
    )
    files = browser.list(
        source="backup", backup=backup, path="/CameraRollDomain/Media/DCIM/100APPLE"
    )["rows"]
    assert len(files) == 1 and files[0]["fileId"] == photo
    preview = browser.preview(source="backup", backup=backup, path=files[0]["path"])
    assert preview["kind"] == "image" and preview["mime"] == "image/jpeg"
    assert base64.b64decode(browser.preview_chunk(preview["token"])["data"]).startswith(b"\xff\xd8")
    out = tmp_path / "export"
    out.mkdir()
    result = browser.operation(
        "download", source="backup", backup=backup, paths=["/CameraRollDomain/Media"], localPath=out
    )
    assert result["count"] == 1 and len(list(out.rglob("*.PNG"))) == 1
    for action in ("rename", "mkdir", "trash", "upload", "restore", "purge"):
        with pytest.raises(ValueError, match="read-only"):
            browser.operation(
                action,
                source="backup",
                backup=backup,
                name="new.txt",
                paths=[files[0]["path"]],
                confirmed=True,
            )
    assert hashlib.sha256((Path(backup) / "Manifest.db").read_bytes()).digest() == before


def test_backup_cached_listing_rechecks_unlock_state(fixture_backup, tmp_path, monkeypatch):
    store, backup, _ = fixture_backup
    browser = FileBrowser(store, tmp_path / "profile")
    browser.list(source="backup", backup=backup)

    def locked(*args):
        raise ValueError("This backup is encrypted. Unlock it with its backup password.")

    monkeypatch.setattr(store, "connection", locked)
    with pytest.raises(ValueError, match="Unlock"):
        browser.list(source="backup", backup=backup)


def test_large_backup_preview_does_not_load_bytes(fixture_backup, tmp_path, monkeypatch):
    store, backup, photo = fixture_backup
    browser = FileBrowser(store, tmp_path / "profile")
    blob = Path(backup) / photo[:2] / photo
    with blob.open("wb") as f:
        f.truncate(257 * 1024 * 1024)
    monkeypatch.setattr(
        store, "bytes", lambda *args: pytest.fail("large preview must reject before reading")
    )
    with pytest.raises(ValueError, match="too large"):
        browser.preview(
            source="backup",
            backup=backup,
            path="/CameraRollDomain/Media/DCIM/100APPLE/IMG_0001.PNG",
        )


class FixtureAfc:
    def __init__(self):
        self.entries = {
            "/": {"st_ifmt": "S_IFDIR"},
            "/Documents": {"st_ifmt": "S_IFDIR"},
            "/Documents/keep.txt": {"st_ifmt": "S_IFREG", "st_size": 4},
        }
        self.moves = []
        self.removals = []

    async def exists(self, path):
        return path in self.entries

    async def stat(self, path):
        return self.entries[path]

    async def listdir(self, path):
        return [
            p.rsplit("/", 1)[-1] for p in self.entries if p != path and posixpath.dirname(p) == path
        ]

    async def makedirs(self, path):
        if path not in self.entries:
            self.entries[path] = {"st_ifmt": "S_IFDIR"}

    async def rename(self, origin, target):
        if target in self.entries:
            raise FileExistsError(target)
        self.entries[target] = self.entries.pop(origin)
        self.moves.append((origin, target))

    async def rm(self, path):
        self.entries.pop(path)
        self.removals.append(path)

    async def rm_single(self, path):
        self.entries.pop(path)
        self.removals.append(path)

    async def fopen(self, path, mode="r"):
        return path

    async def fread(self, handle, length):
        return b"keep"[:length]

    async def fclose(self, handle):
        pass


def fixture_afc(browser, monkeypatch):
    afc = FixtureAfc()

    async def connect(udid, callback):
        return await callback(afc)

    monkeypatch.setattr(browser, "_with_afc", connect)
    return afc


def test_device_trash_restore_and_explicit_purge(fixture_backup, tmp_path, monkeypatch):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    afc = fixture_afc(browser, monkeypatch)
    with pytest.raises(ValueError, match="Confirm"):
        browser.operation("trash", udid=UDID, paths=["/Documents/keep.txt"])
    assert afc.moves == []
    result = browser.operation("trash", udid=UDID, paths=["/Documents/keep.txt"], confirmed=True)
    assert result["recoverable"] and "/Documents/keep.txt" not in afc.entries
    trash = browser.list(udid=UDID, trash=True)["rows"]
    assert trash[0]["original"] == "/Documents/keep.txt"
    browser.operation("restore", udid=UDID, paths=[trash[0]["id"]])
    assert "/Documents/keep.txt" in afc.entries
    browser.operation("trash", udid=UDID, paths=["/Documents/keep.txt"], confirmed=True)
    token = browser.list(udid=UDID, trash=True)["rows"][0]["id"]
    with pytest.raises(ValueError, match="Confirm"):
        browser.operation("purge", udid=UDID, paths=[token])
    assert not afc.removals
    browser.operation("purge", udid=UDID, paths=[token], confirmed=True)
    assert afc.removals and not browser._trash_records(UDID)


def test_restore_collision_keeps_recovery_copy(fixture_backup, tmp_path, monkeypatch):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    afc = fixture_afc(browser, monkeypatch)
    browser.operation("trash", udid=UDID, paths=["/Documents/keep.txt"], confirmed=True)
    item = browser.list(udid=UDID, trash=True)["rows"][0]
    afc.entries["/Documents/keep.txt"] = {"st_ifmt": "S_IFREG"}
    with pytest.raises(ValueError, match="occupied"):
        browser.operation("restore", udid=UDID, paths=[item["id"]])
    assert item["id"] in browser._trash_records(UDID)


def test_device_folder_download_is_bounded_and_collision_safe(
    fixture_backup, tmp_path, monkeypatch
):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    afc = fixture_afc(browser, monkeypatch)
    destination = tmp_path / "download"
    destination.mkdir()
    browser.operation("download", udid=UDID, paths=["/Documents"], localPath=destination)
    assert (destination / "Documents" / "keep.txt").read_bytes() == b"keep"
    with pytest.raises(ValueError, match="already exists"):
        browser.operation("download", udid=UDID, paths=["/Documents"], localPath=destination)
    assert not list(destination.glob(".phosphor-*"))


def test_local_folder_copy_rejects_recursive_destination(fixture_backup, tmp_path):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    root = tmp_path / "local"
    root.mkdir()
    (root / "folder").mkdir()
    (root / "folder" / "a.txt").write_text("a")
    token = browser.register_local(root)["root"]
    destination = tmp_path / "copies"
    destination.mkdir()
    browser.operation(
        "download", source="local", root=token, paths=["/folder"], localPath=destination
    )
    assert (destination / "folder" / "a.txt").read_text() == "a"
    with pytest.raises(ValueError, match="outside"):
        browser.operation(
            "download", source="local", root=token, paths=["/folder"], localPath=root / "folder"
        )


@pytest.mark.parametrize(
    "path",
    [
        "/",
        "/PhosphorTrash",
        "/PhosphorTrash/anything",
        "/DCIM/photo.jpg",
        "/PhotoData/a",
        "/iTunes_Control/a",
    ],
)
def test_ios_managed_library_cannot_be_changed(fixture_backup, tmp_path, monkeypatch, path):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    afc = fixture_afc(browser, monkeypatch)
    with pytest.raises(ValueError):
        browser.operation("trash", udid=UDID, paths=[path], confirmed=True)
    assert not afc.moves and not afc.removals


def test_device_links_are_not_followed(fixture_backup, tmp_path, monkeypatch):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    afc = fixture_afc(browser, monkeypatch)
    afc.entries["/Documents/link"] = {"st_ifmt": "S_IFLNK"}
    with pytest.raises(ValueError, match="links"):
        browser.operation("mkdir", udid=UDID, path="/Documents/link", name="folder")


@pytest.mark.parametrize("fail", [False, True])
def test_device_service_closes_lockdown_on_all_paths(fixture_backup, tmp_path, monkeypatch, fail):
    from pymobiledevice3.services import afc

    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    client = SimpleNamespace(close=AsyncMock())
    monkeypatch.setattr(
        file_browser.device.wireless, "route", lambda udid: {"address": "10.0.0.131"}
    )
    monkeypatch.setattr(file_browser.device.wireless, "connect", AsyncMock(return_value=client))

    class Service:
        def __init__(self, lockdown):
            assert lockdown is client

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

    monkeypatch.setattr(afc, "AfcService", Service)

    async def call(service):
        if fail:
            raise RuntimeError("fixture failure")
        return "ok"

    if fail:
        with pytest.raises(RuntimeError):
            asyncio.run(browser._with_afc(UDID, call))
    else:
        assert asyncio.run(browser._with_afc(UDID, call)) == "ok"
    client.close.assert_awaited_once()


def test_sort_paging_date_range_and_directory_first():
    rows = [
        {"name": "a", "directory": False, "date": "2026-10-02", "size": 20, "kind": "file"},
        {"name": "b", "directory": False, "date": "2026-10-06", "size": 50, "kind": "file"},
        {"name": "Folder", "directory": True, "date": "2026-10-05", "size": None, "kind": "folder"},
    ]
    result = page_rows(
        rows, dateFrom="2026-10-04", dateTo="2026-10-07", sort="size", direction="desc", limit=1
    )
    assert result["total"] == 2 and result["rows"][0]["name"] == "Folder"


def test_local_listing_never_opens_contents(fixture_backup, tmp_path, monkeypatch):
    browser = FileBrowser(fixture_backup[0], tmp_path / "profile")
    root = tmp_path / "local"
    root.mkdir()
    (root / "cloud.txt").write_text("cloud")
    token = browser.register_local(root)["root"]
    monkeypatch.setattr(Path, "open", lambda *a, **k: pytest.fail("listing must use metadata only"))
    assert browser.list(source="local", root=token)["rows"][0]["name"] == "cloud.txt"
