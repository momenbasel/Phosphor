import hashlib
import plistlib
import sqlite3
import struct
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.keywrap import aes_key_wrap
from backup import BackupStore, Decryptor, publish_bytes, safe_component, safe_target
from conftest import encrypted_manifest


def test_read_only_manifest_and_paging(fixture_backup):
    store, backup, photo = fixture_backup
    opened = store.open(backup)
    assert opened["count"] == 11
    assert store.files(backup, query="IMG_", limit=1)["rows"][0]["id"] == photo
    assert store.files(backup, query="%")["total"] == 0
    with store.connection(backup) as db:
        with pytest.raises(sqlite3.OperationalError):
            db.execute("DELETE FROM Files")


@pytest.mark.parametrize(
    "path",
    [
        "../escape",
        "a/../../escape",
        "C:/escape",
        "/absolute",
        "a\\..\\escape",
        "a/file:stream",
        "a//file",
        "a/./file",
    ],
)
def test_windows_traversal_rejected(tmp_path, path):
    with pytest.raises(ValueError):
        safe_target(tmp_path, path)


def test_collision_safe_export(tmp_path):
    file = tmp_path / "hello.txt"
    first = publish_bytes(file, b"first")
    second = publish_bytes(file, b"second")
    assert Path(first).read_bytes() == b"first"
    assert Path(second).read_bytes() == b"second"
    assert first != second
    assert safe_component("CON.txt") == "_CON.txt"
    assert safe_component("hello?.txt") == "hello_.txt"


def test_extract_retains_paths(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    output = tmp_path / "exports"
    store.extract(backup, [photo], output)
    store.extract(backup, [photo], output)
    assert len(list(output.rglob("*.PNG"))) == 2


def test_known_backup_required(tmp_path):
    with pytest.raises(ValueError):
        BackupStore().path(tmp_path)


@pytest.mark.parametrize("wal", [False, True])
def test_encrypted_backup_unlock_and_wrong_password(fixture_backup, wal):
    store, backup, photo = fixture_backup
    root = Path(backup)
    manifest, key = encrypted_manifest("correct horse")
    if wal:
        with sqlite3.connect(root / "Manifest.db") as db:
            assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    plain = (root / "Manifest.db").read_bytes()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).encryptor()
    (root / "Manifest.db").write_bytes(encryptor.update(plain) + encryptor.finalize())
    (root / "Manifest.plist").write_bytes(plistlib.dumps(manifest))
    with pytest.raises(ValueError, match="encrypted"):
        store.open(backup)
    with pytest.raises(ValueError, match="Incorrect"):
        store.open(backup, "wrong")
    assert store.open(backup, "correct horse")["count"] == 11
    assert store.files(backup, query="IMG_")["total"] == 1
    assert (root / "Manifest.db").read_bytes() != plain


def test_encrypted_wal_database_without_sidecars(fixture_backup):
    store, backup, photo = fixture_backup
    root = Path(backup)
    manifest, manifest_key = encrypted_manifest("backup password")
    file_key = b"F" * 32
    with sqlite3.connect(root / "Manifest.db") as db:
        fid = db.execute(
            "SELECT fileID FROM Files WHERE relativePath='Library/SMS/sms.db'"
        ).fetchone()[0]
    source = root / fid[:2] / fid
    with sqlite3.connect(source) as db:
        assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    original = source.read_bytes()
    assert original[18:20] == b"\x02\x02"
    metadata = plistlib.dumps(
        {
            "$objects": [
                "$null",
                {
                    "EncryptionKey": struct.pack("<I", 4)
                    + aes_key_wrap(bytes(range(32)), file_key),
                    "Size": len(original),
                },
            ],
            "$top": {"root": plistlib.UID(1)},
        },
        fmt=plistlib.FMT_BINARY,
    )
    with sqlite3.connect(root / "Manifest.db") as db:
        db.execute("UPDATE Files SET file=? WHERE fileID=?", (metadata, fid))
    for target, key in [(source, file_key), (root / "Manifest.db", manifest_key)]:
        plain = target.read_bytes()
        plain += bytes((-len(plain)) % 16)
        enc = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).encryptor()
        target.write_bytes(enc.update(plain) + enc.finalize())
    (root / "Manifest.plist").write_bytes(plistlib.dumps(manifest))
    encrypted = {p: p.read_bytes() for p in [source, root / "Manifest.db"]}
    store.open(backup, "backup password")
    with store.database(backup, "sms.db") as db:
        assert db.execute("SELECT COUNT(*) FROM message").fetchone()[0] == 2
        with pytest.raises(sqlite3.OperationalError):
            db.execute("DELETE FROM message")
    assert all(p.read_bytes() == data for p, data in encrypted.items())


def test_failed_unlock_does_not_retain_keys(fixture_backup):
    store, backup, photo = fixture_backup
    root = Path(backup)
    with sqlite3.connect(root / "Manifest.db") as db:
        db.execute("DROP TABLE Files")
    manifest, key = encrypted_manifest("correct password")
    enc = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).encryptor()
    (root / "Manifest.db").write_bytes(
        enc.update((root / "Manifest.db").read_bytes()) + enc.finalize()
    )
    (root / "Manifest.plist").write_bytes(plistlib.dumps(manifest))
    with pytest.raises(sqlite3.OperationalError):
        store.open(backup, "correct password")
    assert not store.unlocked


def test_malformed_keybag_rejected():
    with pytest.raises(ValueError):
        Decryptor({"BackupKeyBag": b"UUID\xff\xff\xff\xff"}, "password")


def test_encrypted_file_metadata_and_stream_extract(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    root = Path(backup)
    manifest, manifest_key = encrypted_manifest("backup password")
    file_key = b"F" * 32
    source = root / photo[:2] / photo
    original = source.read_bytes()
    metadata = plistlib.dumps(
        {
            "$objects": [
                "$null",
                {"EncryptionKey": plistlib.UID(2), "Size": len(original)},
                {"NS.data": plistlib.UID(3)},
                struct.pack("<I", 4) + aes_key_wrap(bytes(range(32)), file_key),
            ],
            "$top": {"root": plistlib.UID(1)},
        },
        fmt=plistlib.FMT_BINARY,
    )
    with sqlite3.connect(root / "Manifest.db") as db:
        db.execute("UPDATE Files SET file=? WHERE fileID=?", (metadata, photo))
    for target, key in [(source, file_key), (root / "Manifest.db", manifest_key)]:
        plain = target.read_bytes()
        plain += bytes((-len(plain)) % 16)
        enc = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).encryptor()
        target.write_bytes(enc.update(plain) + enc.finalize())
    (root / "Manifest.plist").write_bytes(plistlib.dumps(manifest))
    store.open(backup, "backup password")
    assert store.bytes(backup, store.entries(backup, [photo])[0]) == original
    store.extract(backup, [photo], tmp_path / "export")
    assert next((tmp_path / "export").rglob("*.PNG")).read_bytes() == original


def test_database_reads_uncheckpointed_wal_without_changing_backup(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    source = tmp_path / "live.sqlite"
    live = sqlite3.connect(source)
    try:
        live.execute("PRAGMA journal_mode=WAL")
        live.execute("PRAGMA wal_autocheckpoint=0")
        live.execute("CREATE TABLE entries (value TEXT)")
        live.execute("INSERT INTO entries VALUES ('visible only with WAL')")
        live.commit()
        root = Path(backup)
        original = {}
        with sqlite3.connect(root / "Manifest.db") as manifest:
            for suffix in ("", "-wal"):
                relative = "Library/Test/live.sqlite" + suffix
                fid = hashlib.sha1(("HomeDomain-" + relative).encode()).hexdigest()
                target = root / fid[:2] / fid
                target.parent.mkdir(exist_ok=True)
                target.write_bytes(Path(str(source) + suffix).read_bytes())
                original[target] = target.read_bytes()
                manifest.execute(
                    "INSERT INTO Files VALUES (?,?,?,?,?)", (fid, "HomeDomain", relative, 1, None)
                )
        with store.database(backup, "live.sqlite") as db:
            assert db.execute("SELECT value FROM entries").fetchone()[0] == "visible only with WAL"
            with pytest.raises(sqlite3.OperationalError):
                db.execute("DELETE FROM entries")
        assert all(path.read_bytes() == data for path, data in original.items())
    finally:
        live.close()
