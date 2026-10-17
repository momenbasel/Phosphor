import base64
import hashlib
import io
import plistlib
import sqlite3
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from PIL import Image

from backup import BackupStore
from conftest import create_encrypted_fixture
from data import DataReader
from gallery import Gallery, MAX_CHUNK, read_range


class Job:
    def __init__(self, cancel_after=None):
        self.checks = 0
        self.cancel_after = cancel_after
        self.progresses = []

    def check(self):
        self.checks += 1
        if self.cancel_after is not None and self.checks >= self.cancel_after:
            raise InterruptedError("Cancelled")

    def progress(self, value, detail):
        self.check()
        self.progresses.append((value, detail))


def add_file(backup, name, raw):
    fid = hashlib.sha1(("CameraRollDomain-" + name).encode()).hexdigest()
    path = Path(backup) / fid[:2] / fid
    path.parent.mkdir(exist_ok=True)
    path.write_bytes(raw)
    metadata = plistlib.dumps(
        {
            "$objects": ["$null", {"Size": len(raw), "Birth": 1704067200}],
            "$top": {"root": plistlib.UID(1)},
        },
        fmt=plistlib.FMT_BINARY,
    )
    with sqlite3.connect(Path(backup) / "Manifest.db") as db:
        db.execute(
            "INSERT INTO Files VALUES (?,?,?,?,?)", [fid, "CameraRollDomain", name, 1, metadata]
        )
    return fid


def image_bytes(color, format="PNG"):
    output = io.BytesIO()
    Image.new("RGB", (50, 50), color).save(output, format)
    return output.getvalue()


def test_cbc_range_read_is_exact_and_bounded(tmp_path):
    plain = bytes(range(256)) * 8500 + b"a short tail"
    key = b"k" * 32
    cipher = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).encryptor()
    source = tmp_path / "encrypted"
    source.write_bytes(cipher.update(plain + bytes((-len(plain)) % 16)) + cipher.finalize())
    descriptor = {"source": source, "key": key, "size": len(plain)}
    for offset, size in [
        (0, 1),
        (15, 90),
        (16, 16),
        (1000001, MAX_CHUNK),
        (len(plain) - 20, 100),
        (len(plain) + 4, 80),
    ]:
        assert read_range(descriptor, offset, size) == plain[offset : offset + size]
    with pytest.raises(ValueError, match="Invalid media range"):
        read_range(descriptor, 0, MAX_CHUNK + 1)
    with pytest.raises(ValueError, match="Invalid media range"):
        read_range(descriptor, -1, 10)


def test_unencrypted_preview_opaque_token_no_source_path(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    preview = gallery.preview(backup, photo)
    assert preview["mime"] == "image/png"
    assert "source" not in preview and "backup" not in preview
    chunk = gallery.preview_chunk(preview["token"], 0, MAX_CHUNK)
    assert base64.b64decode(chunk["data"]) == store.bytes(backup, store.entries(backup, [photo])[0])
    assert chunk["eof"]
    with pytest.raises(ValueError, match="Invalid preview token"):
        gallery.preview_info("../file")
    gallery.release(preview["token"])
    with pytest.raises(ValueError, match="expired"):
        gallery.preview_info(preview["token"])


def test_raw_dng_preview_and_thumbnail_cache_are_revoked_on_lock(fixture_backup, tmp_path):
    from test_media_previews import synthetic_dng

    store, backup, _ = fixture_backup
    source = tmp_path / "original.dng"
    synthetic_dng(source)
    original = source.read_bytes()
    file = add_file(backup, "Media/DCIM/100APPLE/RAW.DNG", original)
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    preview = gallery.preview(backup, file)
    assert preview["mime"] == "image/jpeg" and "cachePath" not in preview
    data = base64.b64decode(gallery.preview_chunk(preview["token"])["data"])
    with Image.open(io.BytesIO(data)) as image:
        assert image.format == "JPEG"
    assert gallery.thumbnail(backup, file).startswith("data:image/jpeg;base64,")
    assert not list(gallery.preview_cache.root.glob("*.source"))
    cached = list(gallery.preview_cache.root.glob("*.jpg"))
    assert cached
    gallery.invalidate(backup)
    assert all(not path.exists() for path in cached)
    assert store.bytes(backup, store.entries(backup, [file])[0]) == original


def test_encrypted_preview_revoked_on_lock(tmp_path):
    backup, photo = create_encrypted_fixture(tmp_path / "backups", "correct fixture password")
    store = BackupStore()
    store.discover([backup])
    store.open(str(backup), "correct fixture password")
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    preview = gallery.preview(str(backup), photo)
    raw = store.bytes(str(backup), store.entries(str(backup), [photo])[0])
    assert base64.b64decode(gallery.preview_chunk(preview["token"], 3, 18)["data"]) == raw[3:21]
    gallery.invalidate(str(backup))
    store.lock(str(backup))
    assert not gallery.tokens
    with pytest.raises(ValueError, match="expired"):
        gallery.preview_info(preview["token"])


def test_review_is_reversible_persistent_and_does_not_mutate_backup(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    before = {
        str(path.relative_to(backup)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in Path(backup).rglob("*")
        if path.is_file()
    }
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    assert gallery.list(backup)["total"] == 1
    gallery.review_set(backup, [photo], "bin")
    assert gallery.list(backup)["total"] == 0
    assert gallery.list(backup, review="bin")["rows"][0]["id"] == photo
    another = Gallery(store, DataReader(store), tmp_path / "profile")
    assert another.review_state(backup)["bin"] == 1
    another.review_set(backup, [photo], "reset")
    assert another.list(backup)["total"] == 1
    assert another.review_state(backup)["bin"] == 0
    after = {
        str(path.relative_to(backup)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in Path(backup).rglob("*")
        if path.is_file()
    }
    assert before == after


def test_review_rejects_non_media_and_foreign_ids(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    with pytest.raises(ValueError, match="unavailable"):
        gallery.review_set(backup, ["a" * 40], "bin")
    with pytest.raises(ValueError, match="Choose"):
        gallery.review_set(backup, [photo], "delete")


def test_exact_duplicates_content_match_and_annotations(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    raw = store.bytes(backup, store.entries(backup, [photo])[0])
    twin = add_file(backup, "Media/DCIM/100APPLE/IMG_COPY.PNG", raw)
    add_file(backup, "Media/DCIM/100APPLE/IMG_DIFFERENT.PNG", image_bytes("red"))
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    result = gallery.scan_duplicates(backup, Job())
    assert result["scanned"] == 3 and not result["truncated"]
    groups = gallery.groups(backup)["groups"]
    assert len(groups) == 1
    assert {row["id"] for row in groups[0]["items"]} == {photo, twin}
    gallery.review_set(backup, [twin], "bin")
    assert (
        next(row for row in gallery.groups(backup)["groups"][0]["items"] if row["id"] == twin)[
            "decision"
        ]
        == "bin"
    )


def test_scan_cancelled_and_limited(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    raw = store.bytes(backup, store.entries(backup, [photo])[0])
    add_file(backup, "Media/DCIM/100APPLE/IMG_COPY.PNG", raw)
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    with pytest.raises(InterruptedError):
        gallery.scan_duplicates(backup, Job(cancel_after=2))
    assert not gallery.groups(backup)["ready"]
    result = gallery.scan_duplicates(backup, Job(), max_items=1)
    assert result["truncated"] and result["scanned"] == 1


def test_similar_matches_are_suggestions_not_exact(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    add_file(backup, "Media/DCIM/100APPLE/IMG_SIMILAR.PNG", image_bytes("#b4ca86"))
    gallery = Gallery(store, DataReader(store), tmp_path / "profile")
    gallery.scan_duplicates(backup, Job(), mode="similar")
    result = gallery.groups(backup, "similar")
    assert result["similarSuggestions"]
    assert result["groups"][0]["kind"] == "similar"
    assert gallery.review_state(backup)["bin"] == 0
