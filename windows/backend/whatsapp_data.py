"""Identify chat content separately from WhatsApp caches and cloud placeholders."""

import sqlite3
from contextlib import contextmanager

from backup import DatasetUnavailable, archive_metadata
from data_queries import validate_schema

FILENAMES = ("chatstorage.sqlite", "chatstorage.db", "chatstorage.sqlite.enc", "chatstorage.db.enc")
LIMIT = 100


def basename(entry):
    return str(entry["relativePath"]).replace("\\", "/").rsplit("/", 1)[-1]


def recorded_size(entry):
    size = archive_metadata(entry.get("file")).get("Size")
    return size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else None


@contextmanager
def database(store, backup):
    with store.connection(backup) as manifest:
        facts = manifest.execute(
            "SELECT COUNT(*) AS count,COUNT(DISTINCT domain) AS domains FROM Files WHERE instr(lower(domain),'whatsapp')>0 OR instr(lower(relativePath),'whatsapp')>0"
        ).fetchone()
        candidates = [
            dict(row)
            for row in manifest.execute(
                "SELECT * FROM Files WHERE flags=1 AND (instr(lower(domain),'whatsapp')>0 OR instr(lower(relativePath),'whatsapp')>0) AND (lower(relativePath) GLOB '*.sqlite' OR lower(relativePath) GLOB '*.db' OR lower(relativePath) LIKE '%chatstorage%') ORDER BY CASE WHEN lower(relativePath) LIKE '%chatstorage%' THEN 0 ELSE 1 END,relativePath LIMIT ?",
                [LIMIT],
            )
        ]
    evidence = {
        "relatedEntries": facts["count"],
        "relatedDomains": facts["domains"],
        "candidateLimit": LIMIT,
        "auxiliaryDatabases": 0,
        "unreadableDatabases": 0,
        "unsupportedChatDatabases": 0,
        "emptyChatArchives": 0,
        "emptyCloudArchives": 0,
        "protectedChatArchives": 0,
    }
    unreadable_chat = False
    for entry in candidates:
        name = basename(entry).lower()
        named = name in FILENAMES
        encoded = named and name.endswith(".enc")
        try:
            header = store.header(backup, entry, 16)
            if named and (not header or recorded_size(entry) == 0 and not any(header)):
                evidence["emptyChatArchives"] += 1
                if encoded and "/mobile documents/" in "/" + str(entry["relativePath"]).lower():
                    evidence["emptyCloudArchives"] += 1
                continue
            if header != b"SQLite format 3\0":
                if encoded:
                    evidence["protectedChatArchives"] += 1
                elif named:
                    unreadable_chat = True
                continue
        except (OSError, ValueError, KeyError):
            evidence["unreadableDatabases"] += 1
            unreadable_chat = unreadable_chat or named
            continue
        manager = store.database_entry(backup, entry)
        try:
            db = manager.__enter__()
            tables = {
                row[0].lower()
                for row in db.execute(
                    "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
                )
            }
            chat_like = named or bool(
                tables
                & {"zwachatsession", "zwamessage", "zchatsession", "zmessage", "chat", "message"}
            )
            supported = "zwachatsession" in tables and validate_schema(db, "whatsapp")
        except (sqlite3.DatabaseError, ValueError, OSError):
            evidence["unreadableDatabases"] += 1
            unreadable_chat = unreadable_chat or named
            manager.__exit__(None, None, None)
            continue
        if supported:
            try:
                yield db
            finally:
                manager.__exit__(None, None, None)
            return
        manager.__exit__(None, None, None)
        evidence["unsupportedChatDatabases" if chat_like else "auxiliaryDatabases"] += 1
    if evidence["unsupportedChatDatabases"]:
        status = "unsupported"
        reason = "unknown_chat_schema"
        message = "A WhatsApp chat database contains data, but its chat schema is not supported yet. Auxiliary databases are not counted as chat databases."
    elif unreadable_chat:
        status = "unreadable"
        reason = "chat_database_unreadable"
        message = "A WhatsApp chat database is recorded, but its contents could not be read. The original backup has not been changed."
    elif evidence["protectedChatArchives"]:
        status = "protected"
        reason = "app_protected_archive"
        message = "This snapshot contains a nonempty ChatStorage archive protected by WhatsApp. Unlocking the computer backup does not unlock this app-specific archive; Phosphor cannot currently decode this format."
    elif evidence["emptyChatArchives"]:
        status = "cloud_only" if evidence["emptyCloudArchives"] else "empty"
        reason = "empty_chat_archive"
        message = "This snapshot contains only an empty ChatStorage archive (0 bytes). The WhatsApp chat contents are not in this backup. The other databases belong to auxiliary app data; they are not conversations. Unlocking the computer backup cannot recover missing chat bytes."
    else:
        status = "missing"
        reason = "chat_database_absent"
        message = (
            "WhatsApp-related entries are recorded, but no readable chat database is included in this backup."
            if facts["count"]
            else "No WhatsApp-related app domains or paths are recorded in this backup."
        )
    evidence["reason"] = reason
    raise DatasetUnavailable(status, message, evidence)
