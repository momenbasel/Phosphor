import hashlib
import io
import plistlib
import sqlite3
import struct
import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from backup import BackupStore
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.keywrap import aes_key_wrap


def encrypted_manifest(password):
    salt = b"salt1234"
    double = b"double12"
    class_key = bytes(range(32))
    file_key = bytes(reversed(range(32)))
    secret = hashlib.pbkdf2_hmac("sha256", password.encode(), double, 2, 32)
    secret = hashlib.pbkdf2_hmac("sha1", secret, salt, 2, 32)

    def tlv(tag, value):
        return tag.encode() + struct.pack(">I", len(value)) + value

    def number(tag, value):
        return tlv(tag, struct.pack(">I", value))

    bag = (
        tlv("UUID", bytes(16))
        + number("WRAP", 2)
        + tlv("SALT", salt)
        + number("ITER", 2)
        + tlv("DPSL", double)
        + number("DPIC", 2)
        + tlv("UUID", b"a" * 16)
        + number("CLAS", 4)
        + number("WRAP", 2)
        + tlv("WPKY", aes_key_wrap(secret, class_key))
    )
    return {
        "IsEncrypted": True,
        "BackupKeyBag": bag,
        "ManifestKey": struct.pack("<I", 4) + aes_key_wrap(class_key, file_key),
    }, file_key


def create_encrypted_fixture(root, password):
    backup, photo = create_fixture(root)
    manifest, manifest_key = encrypted_manifest(password)
    file_key = b"F" * 32

    def encrypt(target, key):
        plain = target.read_bytes()
        plain += bytes((-len(plain)) % 16)
        ctx = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).encryptor()
        target.write_bytes(ctx.update(plain) + ctx.finalize())

    with sqlite3.connect(backup / "Manifest.db") as db:
        assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        rows = db.execute("SELECT fileID,relativePath FROM Files").fetchall()
        for fid, relative in rows:
            source = backup / fid[:2] / fid
            if relative.endswith("sms.db"):
                with sqlite3.connect(source) as messages:
                    assert messages.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
                messages.close()
            meta = plistlib.dumps(
                {
                    "$objects": [
                        "$null",
                        {
                            "EncryptionKey": struct.pack("<I", 4)
                            + aes_key_wrap(bytes(range(32)), file_key),
                            "Size": source.stat().st_size,
                        },
                    ],
                    "$top": {"root": plistlib.UID(1)},
                },
                fmt=plistlib.FMT_BINARY,
            )
            db.execute("UPDATE Files SET file=? WHERE fileID=?", (meta, fid))
            encrypt(source, file_key)
    db.close()
    encrypt(backup / "Manifest.db", manifest_key)
    (backup / "Manifest.plist").write_bytes(plistlib.dumps(manifest))
    return backup, photo


def create_fixture(root):
    root = Path(root)
    backup = root / "00008030-001234567890ABCD"
    backup.mkdir(parents=True, exist_ok=True)

    def plist(name, values):
        (backup / name).write_bytes(plistlib.dumps(values))

    plist(
        "Info.plist",
        {
            "Device Name": "Test iPhone",
            "Product Type": "iPhone15,2",
            "Product Version": "18.0",
            "Target Identifier": backup.name,
            "Last Backup Date": datetime(2026, 10, 7, 12),
        },
    )
    plist("Manifest.plist", {"IsEncrypted": False})
    plist("Status.plist", {"SnapshotState": "finished", "Date": datetime(2026, 10, 7, 12)})
    manifest = sqlite3.connect(backup / "Manifest.db")
    manifest.execute(
        "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)"
    )

    def add(domain, path, data):
        fid = hashlib.sha1((domain + "-" + path).encode()).hexdigest()
        folder = backup / fid[:2]
        folder.mkdir(exist_ok=True)
        (folder / fid).write_bytes(data)
        manifest.execute("INSERT INTO Files VALUES (?,?,?,?,?)", [fid, domain, path, 1, None])
        return fid

    def database(name, script):
        db = sqlite3.connect(":memory:")
        db.executescript(script)
        data = db.serialize()
        db.close()
        return add("HomeDomain", name, data)

    database(
        "Library/SMS/sms.db",
        """
    CREATE TABLE chat (chat_identifier TEXT, display_name TEXT);
    CREATE TABLE message (date INTEGER, is_from_me INTEGER, handle_id INTEGER, text TEXT, attributedBody BLOB);
    CREATE TABLE handle (id TEXT);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    INSERT INTO chat VALUES ('+15550101','Alex');
    INSERT INTO handle VALUES ('+15550101');
    INSERT INTO message VALUES (800000000000000000,0,1,'A memory worth keeping.',NULL);
    INSERT INTO message VALUES (800000001000000000,1,1,'<script>alert(1)</script>',NULL);
    INSERT INTO chat_message_join VALUES (1,1),(1,2);
    """,
    )
    database(
        "Library/AddressBook/AddressBook.sqlitedb",
        """
    CREATE TABLE ABPerson (First TEXT,Last TEXT,Organization TEXT);
    CREATE TABLE ABMultiValue (record_id INTEGER,property INTEGER,value TEXT);
    INSERT INTO ABPerson VALUES ('Alex','River','Studio'),('=FORMULA','Person','');
    INSERT INTO ABMultiValue VALUES (1,3,'+15550101'),(1,4,'alex@example.test');
    """,
    )
    database(
        "Library/Calendar/Calendar.sqlitedb",
        """
    CREATE TABLE CalendarItem (summary TEXT,start_date REAL,end_date REAL,all_day INTEGER,description TEXT);
    INSERT INTO CalendarItem VALUES ('Weekend; trip',800000000,800086400,1,'Line one'||char(10)||'Line two');
    """,
    )
    database(
        "Library/Notes/NoteStore.sqlite",
        """
    CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER,ZTITLE1 TEXT,ZSNIPPET TEXT,ZMODIFICATIONDATE1 REAL,ZISPASSWORDPROTECTED INTEGER);
    INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (1,'A small thought','Keep the things that matter.',800000000,0);
    """,
    )
    database(
        "Library/CallHistoryDB/CallHistory.storedata",
        """
    CREATE TABLE ZCALLRECORD (Z_PK INTEGER,ZADDRESS TEXT,ZDATE REAL,ZDURATION REAL,ZCALLTYPE INTEGER);
    INSERT INTO ZCALLRECORD VALUES (1,'+15550101',800000000,65,1);
    """,
    )
    database(
        "Library/Safari/History.db",
        """
    CREATE TABLE history_items (id INTEGER,title TEXT,url TEXT,visit_count INTEGER);
    CREATE TABLE history_visits (history_item INTEGER,visit_time REAL);
    INSERT INTO history_items VALUES (1,'Example','https://example.test',2);
    INSERT INTO history_visits VALUES (1,800000000);
    """,
    )
    from PIL import Image

    image = Image.new("RGB", (50, 50), "#b4ca85")
    out = io.BytesIO()
    image.save(out, "PNG")
    photo = add("CameraRollDomain", "Media/DCIM/100APPLE/IMG_0001.PNG", out.getvalue())
    add("HomeDomain", "Library/Health/healthdb.sqlite", b"health fixture")
    add("HomeDomain", "Library/Watch/test.plist", b"watch fixture")
    add("MediaDomain", "Recordings/voice.m4a", b"audio fixture")
    add("AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "ChatStorage.sqlite", make_whatsapp())
    manifest.commit()
    manifest.close()
    return backup, photo


def make_whatsapp():
    db = sqlite3.connect(":memory:")
    db.executescript(
        """CREATE TABLE ZWACHATSESSION (Z_PK INTEGER,ZPARTNERNAME TEXT,ZCONTACTJID TEXT,ZMESSAGECOUNTER INTEGER,ZLASTMESSAGEDATE REAL);
    CREATE TABLE ZWAMESSAGE (Z_PK INTEGER,ZCHATSESSION INTEGER,ZTEXT TEXT,ZMESSAGEDATE REAL,ZISFROMME INTEGER,ZFROMJID TEXT);
    INSERT INTO ZWACHATSESSION VALUES (1,'Alex','15550101@s.whatsapp.net',1,800000000);
    INSERT INTO ZWAMESSAGE VALUES (1,1,'Hello from the fixture',800000000,0,'15550101@s.whatsapp.net');"""
    )
    data = db.serialize()
    db.close()
    return data


@pytest.fixture
def fixture_backup(tmp_path):
    backup, photo = create_fixture(tmp_path)
    store = BackupStore()
    store.discover([tmp_path])
    return store, str(backup), photo
