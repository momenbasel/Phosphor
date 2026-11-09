"""Read-only Apple backup access, encryption, and collision-safe extraction."""

import hashlib
import plistlib
import re
import sqlite3
import struct
import threading
import tempfile
from collections import OrderedDict
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.keywrap import aes_key_unwrap, InvalidUnwrap


def load_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def iso(value):
    if isinstance(value, datetime):
        return value.replace(tzinfo=timezone.utc).isoformat()
    return str(value) if value is not None else ""


def safe_component(value):
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", str(value)).rstrip(" .")[:180]
    if not value or value in (".", ".."):
        value = "_"
    if re.match(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", value, re.I):
        value = "_" + value
    return value


def safe_target(root, relative):
    """Refuse traversal, drive prefixes, ADS and reparse points, including on Windows."""
    relative = str(relative).replace("\\", "/")
    parts = relative.split("/")
    if relative.startswith("/") or any(
        p in ("", ".", "..") or ":" in p or "\x00" in p for p in parts
    ):
        raise ValueError("Unsafe path in backup or archive: " + relative[:150])
    root = Path(root).resolve()
    target = root.joinpath(*parts)
    if not target.resolve().is_relative_to(root):
        raise ValueError("The extraction path leaves the destination folder.")
    for p in [target, *target.parents]:
        if p == root.parent:
            break
        if p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction()):
            raise ValueError("Extraction through a link or junction is not allowed.")
    return target


def publish_bytes(target, data):
    """O_EXCL gives atomic collision reservation, never replacing existing exports."""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    candidate = target
    n = 1
    while True:
        try:
            with candidate.open("xb") as f:
                f.write(data)
            return str(candidate)
        except FileExistsError:
            n += 1
            candidate = target.with_name(f"{target.stem} ({n}){target.suffix}")
        except Exception:
            candidate.unlink(missing_ok=True)
            raise


class Decryptor:
    def __init__(self, manifest, password):
        blob = manifest.get("BackupKeyBag", b"")
        attrs, classes, current = {}, [], None
        offset = 0
        while offset < len(blob):
            if offset + 8 > len(blob):
                raise ValueError("The backup keybag is incomplete.")
            tag, length = struct.unpack(">4sI", blob[offset : offset + 8])
            offset += 8
            if length > len(blob) - offset:
                raise ValueError("The backup keybag is malformed.")
            tag = tag.decode("ascii")
            value = blob[offset : offset + length]
            offset += length
            if tag == "UUID" and "UUID" in attrs:
                current = {}
                classes.append(current)
            elif current is not None:
                current[tag] = value
            else:
                attrs[tag] = value
        integer = lambda d, key: int.from_bytes(d.get(key, b"\0"), "big")
        iterations = integer(attrs, "ITER")
        if not 0 < iterations <= 100_000_000 or not attrs.get("SALT"):
            raise ValueError("The backup keybag has invalid password parameters.")
        secret = password.encode("utf-8")
        if "DPSL" in attrs:
            double = integer(attrs, "DPIC")
            if not 0 < double <= 100_000_000:
                raise ValueError("The backup keybag has invalid password parameters.")
            secret = hashlib.pbkdf2_hmac("sha256", secret, attrs["DPSL"], double, 32)
        secret = hashlib.pbkdf2_hmac("sha1", secret, attrs["SALT"], iterations, 32)
        self.keys = {}
        try:
            for item in classes:
                if integer(item, "WRAP") & 2:
                    self.keys[integer(item, "CLAS")] = aes_key_unwrap(secret, item["WPKY"])
            if not self.keys:
                raise ValueError("No password-wrapped keys found in this backup.")
            self.manifest_key = self.unwrap(manifest["ManifestKey"])
        except (InvalidUnwrap, KeyError) as e:
            raise ValueError("Incorrect backup password, or an unsupported keybag.") from e

    def unwrap(self, blob):
        protection = struct.unpack("<I", blob[:4])[0]
        return aes_key_unwrap(self.keys[protection], blob[4:])

    @staticmethod
    def decrypt(data, key):
        ctx = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).decryptor()
        return ctx.update(data) + ctx.finalize()


def archive_metadata(blob):
    if not blob:
        return {}
    try:
        p = plistlib.loads(blob)
        objects = p.get("$objects", [])

        def resolve(x, depth=0):
            if depth > 16:
                return None
            if isinstance(x, plistlib.UID):
                return resolve(objects[x.data], depth + 1)
            if isinstance(x, dict):
                if "NS.data" in x:
                    return resolve(x["NS.data"], depth + 1)
                return {k: resolve(v, depth + 1) for k, v in x.items() if k != "$class"}
            return x

        return resolve(p.get("$top", {}).get("root", {})) or {}
    except (ValueError, IndexError, KeyError, TypeError, plistlib.InvalidFileException):
        return {}


def memory_database(data, shared=False):
    """Open a standalone decrypted SQLite image without writing plaintext to disk."""
    if len(data) < 100 or not data.startswith(b"SQLite format 3\0"):
        raise ValueError("The decrypted file is not a readable SQLite database.")
    # sqlite3_deserialize cannot read WAL-mode images. Standalone backup images
    # have no pending WAL; databases with companions use database()'s copy path.
    # https://sqlite.org/c3ref/deserialize.html
    if data[18:20] == b"\x02\x02":
        data = data[:18] + b"\x01\x01" + data[20:]
    conn = sqlite3.connect(":memory:", check_same_thread=not shared)
    try:
        conn.deserialize(data)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA query_only=ON")
        return conn
    except Exception:
        conn.close()
        raise


class DatasetUnavailable(ValueError):
    """An optional dataset is absent or has an unsupported schema."""

    def __init__(self, status, message, details=None):
        super().__init__(message)
        self.status = status
        self.details = details or {}


class BackupStore:
    def __init__(self):
        self.known = set()
        self.unlocked = OrderedDict()
        self.generations = {}
        self.guard = threading.RLock()

    def discover(self, roots):
        result, seen = [], set()
        for root in roots:
            root = Path(root).expanduser()
            if not root.is_dir():
                continue
            candidates = (
                [root] + list(root.glob("*")) + list(root.glob("*/*")) + list(root.glob("*/*/*"))
            )
            for candidate in candidates:
                if (
                    not candidate.is_dir()
                    or ".inprogress" in candidate.parts
                    or not (candidate / "Info.plist").is_file()
                ):
                    continue
                p = str(candidate.resolve())
                if p in seen:
                    continue
                seen.add(p)
                try:
                    info = load_plist(candidate / "Info.plist")
                    manifest = (
                        load_plist(candidate / "Manifest.plist")
                        if (candidate / "Manifest.plist").exists()
                        else {}
                    )
                    status = (
                        load_plist(candidate / "Status.plist")
                        if (candidate / "Status.plist").exists()
                        else {}
                    )
                    complete = status.get("SnapshotState") == "finished"
                    result.append(
                        {
                            "id": p,
                            "path": p,
                            "name": info.get("Device Name", "iOS device"),
                            "udid": info.get(
                                "Target Identifier", info.get("Unique Identifier", candidate.name)
                            ),
                            "model": info.get("Product Type", ""),
                            "ios": info.get("Product Version", ""),
                            "date": iso(info.get("Last Backup Date", status.get("Date"))),
                            "encrypted": bool(manifest.get("IsEncrypted")),
                            "unlocked": p in self.unlocked,
                            "complete": complete,
                            "manifest": (candidate / "Manifest.db").exists(),
                        }
                    )
                    self.known.add(p)
                except (OSError, ValueError, plistlib.InvalidFileException):
                    continue
        return sorted(result, key=lambda x: x["date"], reverse=True)

    def path(self, backup):
        p = str(Path(backup).resolve())
        if p not in self.known:
            raise ValueError("Choose a discovered backup in Phosphor first.")
        return Path(p)

    def open(self, backup, password=None):
        path = self.path(backup)
        manifest = load_plist(path / "Manifest.plist")
        session = None
        if manifest.get("IsEncrypted") and password is not None:
            dec = Decryptor(manifest, password)
            data = dec.decrypt((path / "Manifest.db").read_bytes(), dec.manifest_key)
            if not data.startswith(b"SQLite format 3\0"):
                raise ValueError("The decrypted manifest is invalid. Check the backup password.")
            # Reuse one query-only in-memory manifest per unlocked snapshot. A
            # large manifest is not copied/deserialized for every thumbnail.
            session = (dec, memory_database(data, shared=True))
        try:
            connection = (
                self.connection(backup) if session is None else self._session_connection(session)
            )
            with connection as conn:
                domains = [
                    dict(r)
                    for r in conn.execute(
                        "SELECT domain AS name, COUNT(*) AS count FROM Files WHERE flags=1 GROUP BY domain ORDER BY domain"
                    )
                ]
                count = conn.execute("SELECT COUNT(*) FROM Files WHERE flags=1").fetchone()[0]
                if session:
                    # The runtime-only partial index makes domain/folder range
                    # scans fast. Its connection owns a deserialized RAM copy;
                    # the encrypted manifest on disk is never changed.
                    conn.execute("PRAGMA query_only=OFF")
                    try:
                        conn.execute(
                            "CREATE INDEX IF NOT EXISTS phosphor_file_path ON Files(domain,relativePath) WHERE flags=1"
                        )
                    finally:
                        conn.execute("PRAGMA query_only=ON")
        except Exception:
            if session:
                session[1].close()
            raise
        if session:
            with self.guard:
                self._lock_path(str(path))
                self.unlocked[str(path)] = session
                self.generations[str(path)] = self.generations.get(str(path), 0) + 1
                while len(self.unlocked) > 2:
                    oldest = next(iter(self.unlocked))
                    self._lock_path(oldest)
        return {"domains": domains, "count": count, "path": str(path)}

    @contextmanager
    def _session_connection(self, session):
        with self.guard:
            yield session[1]

    def _lock_path(self, path):
        session = self.unlocked.pop(path, None)
        if session:
            session[1].close()
        self.generations[path] = self.generations.get(path, 0) + 1

    def lock(self, backup):
        with self.guard:
            self._lock_path(str(self.path(backup)))

    def generation(self, backup):
        path = str(self.path(backup))
        with self.guard:
            return self.generations.get(path, 0)

    @contextmanager
    def connection(self, backup):
        p = self.path(backup)
        encrypted = load_plist(p / "Manifest.plist").get("IsEncrypted", False)
        if encrypted:
            with self.guard:
                session = self.unlocked.get(str(p))
                if not session:
                    raise ValueError(
                        "This backup is encrypted. Unlock it with its backup password."
                    )
                self.unlocked.move_to_end(str(p))
                yield session[1]
            return
        else:
            conn = sqlite3.connect((p / "Manifest.db").as_uri() + "?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA query_only=ON")
        try:
            yield conn
        finally:
            conn.close()

    def files(self, backup, query="", domain="", offset=0, limit=100):
        where = "flags=1 AND relativePath LIKE ? ESCAPE '\\'"
        escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        args = ["%" + escaped + "%"]
        if domain:
            where += " AND domain=?"
            args.append(domain)
        with self.connection(backup) as conn:
            count = conn.execute("SELECT COUNT(*) FROM Files WHERE " + where, args).fetchone()[0]
            rows = [
                dict(r)
                for r in conn.execute(
                    "SELECT fileID AS id, domain, relativePath AS path, flags FROM Files WHERE "
                    + where
                    + " ORDER BY domain, relativePath LIMIT ? OFFSET ?",
                    [*args, min(500, max(1, int(limit))), max(0, int(offset))],
                )
            ]
        return {"rows": rows, "total": count}

    def entries(self, backup, ids):
        if not ids or len(ids) > 10000:
            raise ValueError("Select between 1 and 10,000 files at a time.")
        with self.connection(backup) as conn:
            return [
                dict(r)
                for r in conn.execute(
                    "SELECT * FROM Files WHERE flags=1 AND fileID IN ("
                    + ",".join("?" for _ in ids)
                    + ")",
                    ids,
                )
            ]

    def bytes(self, backup, entry):
        file_id = entry["fileID"]
        if not re.fullmatch(r"[a-fA-F0-9]{40}", file_id):
            raise ValueError("Invalid backup file identifier.")
        base = self.path(backup)
        p = base / file_id[:2] / file_id
        if not p.exists():
            p = base / file_id
        if not p.resolve().is_relative_to(base) or p.is_symlink():
            raise ValueError("The backup file is outside the backup directory.")
        data = p.read_bytes()
        with self.guard:
            session = self.unlocked.get(str(base))
        if session:
            meta = archive_metadata(entry["file"])
            if not meta.get("EncryptionKey"):
                raise ValueError("This backup file has no encryption key.")
            data = session[0].decrypt(data, session[0].unwrap(meta["EncryptionKey"]))
            size = meta.get("Size")
            if isinstance(size, int) and 0 <= size <= len(data):
                data = data[:size]
        return data

    def header(self, backup, entry, length=100):
        """Inspect a bounded file prefix, including encrypted database candidates."""
        length = max(0, min(4096, int(length)))
        file_id = entry["fileID"]
        if not re.fullmatch(r"[a-fA-F0-9]{40}", file_id):
            raise ValueError("Invalid backup file identifier.")
        base = self.path(backup)
        source = base / file_id[:2] / file_id
        if not source.exists():
            source = base / file_id
        if source.is_symlink() or not source.resolve().is_relative_to(base):
            raise ValueError("The backup file is outside the backup directory.")
        with self.guard:
            session = self.unlocked.get(str(base))
        with source.open("rb") as stream:
            data = stream.read(((length + 15) // 16) * 16 if session else length)
        if session:
            metadata = archive_metadata(entry["file"])
            wrapped = metadata.get("EncryptionKey")
            if wrapped:
                if len(data) % 16:
                    raise ValueError("The encrypted backup file is incomplete.")
                data = session[0].decrypt(data, session[0].unwrap(wrapped))
        return data[:length]

    @contextmanager
    def database_entry(self, backup, entry):
        with self.connection(backup) as conn:
            sidecars = [
                dict(r)
                for r in conn.execute(
                    "SELECT * FROM Files WHERE flags=1 AND domain=? AND relativePath IN (?,?)",
                    [
                        entry["domain"],
                        entry["relativePath"] + "-wal",
                        entry["relativePath"] + "-shm",
                    ],
                )
            ]
        if not sidecars:
            if str(self.path(backup)) in self.unlocked:
                data = self.bytes(backup, entry)
                if not data.startswith(b"SQLite format 3\0"):
                    raise ValueError("This backup entry is not a readable SQLite database.")
                db = memory_database(data)
            else:
                file_id = entry["fileID"]
                if not re.fullmatch(r"[a-fA-F0-9]{40}", file_id):
                    raise ValueError("Invalid backup file identifier.")
                source = self.path(backup) / file_id[:2] / file_id
                if not source.exists():
                    source = self.path(backup) / file_id
                if not source.resolve().is_relative_to(self.path(backup)):
                    raise ValueError("Invalid backup database path.")
                db = sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)
            try:
                db.row_factory = sqlite3.Row
                db.execute("PRAGMA query_only=ON")
                yield db
            finally:
                db.close()
        else:
            # Reconstruct companion WAL files in an isolated temporary copy. The
            # original backup is never opened for writing or checkpointing.
            with tempfile.TemporaryDirectory(prefix="phosphor-sqlite-") as folder:
                target = Path(folder) / "data.sqlite"
                target.write_bytes(self.bytes(backup, entry))
                for companion in sidecars:
                    target.with_name(
                        "data.sqlite"
                        + ("-wal" if companion["relativePath"].endswith("-wal") else "-shm")
                    ).write_bytes(self.bytes(backup, companion))
                db = sqlite3.connect(target.as_uri() + "?mode=ro", uri=True)
                try:
                    db.row_factory = sqlite3.Row
                    db.execute("PRAGMA query_only=ON")
                    yield db
                finally:
                    db.close()

    @contextmanager
    def database(
        self,
        backup,
        suffix,
        expected_tables=(),
        domain_hints=(),
        path_hints=(),
        validator=None,
        entry_validator=None,
        candidate_entries=None,
    ):
        # A filename is not an identity: many applications have History.db.
        # Rank native locations first, then inspect every candidate schema.
        names = [suffix] if isinstance(suffix, str) else list(suffix)
        if candidate_entries is None:
            with self.connection(backup) as conn:
                predicate = " OR ".join(
                    "(lower(relativePath)=? OR lower(relativePath) LIKE ?)" for _ in names
                )
                args = [v for name in names for v in (name.lower(), "%/" + name.lower())]
                entries = [
                    dict(r)
                    for r in conn.execute(
                        "SELECT * FROM Files WHERE flags=1 AND (" + predicate + ")", args
                    )
                ]
        else:
            entries = list(candidate_entries)
        if entry_validator:
            entries = [entry for entry in entries if entry_validator(entry)]
        if not entries:
            raise DatasetUnavailable(
                "missing", "This data is not included in this backup.", {"filenames": names}
            )

        def rank(entry):
            domain = entry["domain"].lower()
            path = entry["relativePath"].lower()
            return (
                sum(h.lower() in domain for h in domain_hints) * 10
                + sum(h.lower() in path for h in path_hints),
                path,
            )

        entries.sort(key=rank, reverse=True)
        rejected = 0
        for entry in entries:
            manager = self.database_entry(backup, entry)
            try:
                db = manager.__enter__()
                tables = {
                    r[0].lower()
                    for r in db.execute(
                        "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
                    )
                }
                supported = all(t.lower() in tables for t in expected_tables) and (
                    validator(db) if validator else True
                )
            except (sqlite3.DatabaseError, ValueError, OSError):
                rejected += 1
                manager.__exit__(None, None, None)
                continue
            if not supported:
                rejected += 1
                manager.__exit__(None, None, None)
                continue
            try:
                yield db
            finally:
                manager.__exit__(None, None, None)
            return
        raise DatasetUnavailable(
            "unsupported",
            "A database was found, but its data format is not supported yet.",
            {"filenames": names, "candidates": len(entries), "rejected": rejected},
        )

    def extract(self, backup, ids, destination, job=None):
        paths = []
        entries = self.entries(backup, ids)
        for index, entry in enumerate(entries):
            if job:
                job.check()
            raw = str(entry["relativePath"]).replace("\\", "/")
            safe_target(destination, entry["domain"] + "/" + raw)
            parts = [safe_component(entry["domain"]), *[safe_component(x) for x in raw.split("/")]]
            target = safe_target(destination, "/".join(parts))
            # Stream large videos/app data rather than holding entire files in RAM.
            base = self.path(backup)
            file_id = entry["fileID"]
            if not re.fullmatch(r"[a-fA-F0-9]{40}", file_id):
                raise ValueError("Invalid backup file identifier.")
            source = base / file_id[:2] / file_id
            if not source.exists():
                source = base / file_id
            if not source.resolve().is_relative_to(base):
                raise ValueError("The source file is outside the backup.")
            session = self.unlocked.get(str(base))
            ctx = None
            remaining = None
            if session:
                meta = archive_metadata(entry["file"])
                key = session[0].unwrap(meta["EncryptionKey"])
                ctx = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).decryptor()
                remaining = meta.get("Size")
            target.parent.mkdir(parents=True, exist_ok=True)
            candidate = target
            n = 1
            while True:
                try:
                    out = candidate.open("xb")
                    break
                except FileExistsError:
                    n += 1
                    candidate = target.with_name(f"{target.stem} ({n}){target.suffix}")
            try:
                with out, source.open("rb") as src:
                    while chunk := src.read(1024 * 1024):
                        if job:
                            job.check()
                        plain = ctx.update(chunk) if ctx else chunk
                        if isinstance(remaining, int):
                            plain = plain[: max(0, remaining)]
                            remaining -= len(plain)
                        out.write(plain)
                    if ctx:
                        final = ctx.finalize()
                        out.write(
                            final[: max(0, remaining)] if isinstance(remaining, int) else final
                        )
                paths.append(str(candidate))
            except Exception:
                candidate.unlink(missing_ok=True)
                raise
            if job:
                job.progress((index + 1) / len(entries) * 100, "Extracting selected backup files")
        return {"count": len(paths), "output": str(Path(destination).resolve())}
