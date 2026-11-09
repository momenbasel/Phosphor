"""Bounded, schema-aware backup readers and portable exports."""

import base64
import csv
import html
import io
import json
import sqlite3
import threading
from collections import OrderedDict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from backup import publish_bytes, DatasetUnavailable
import data_queries
import whatsapp_data
from media_index import MediaIndexes
from note_text import decode_note_text

EPOCH = 978307200


def apple_date(value):
    if value is None:
        return ""
    try:
        value = float(value)
        if abs(value) > 1e12:
            value /= 1e9
        return datetime.fromtimestamp(value + EPOCH, timezone.utc).isoformat()
    except (ValueError, OverflowError, OSError):
        return ""


def cols(db, table):
    return {r["name"] for r in db.execute(f'PRAGMA table_info("{table}")')}


def text_body(text, attributed):
    if text:
        return text
    if attributed:
        try:
            import typedstream

            result = typedstream.unarchive_from_data(attributed)

            def find_string(value, depth=0):
                if depth > 16:
                    return None
                if isinstance(value, typedstream.types.foundation.NSString):
                    return value.value
                for field in ("string", "value", "super_object", "contents", "values"):
                    child = getattr(value, field, None)
                    if child is value:
                        continue
                    children = child if isinstance(child, (list, tuple)) else [child]
                    for item in children:
                        if item is not None:
                            found = find_string(item, depth + 1)
                            if found is not None:
                                return found
                return None

            decoded = find_string(result)
            if decoded is not None:
                return decoded
            return "[Rich text message — extract sms.db to retain the original]"
        except Exception:
            return "[Rich text message — extract sms.db to retain the original]"
    return "[Attachment or system message]"


class DataReader:
    def __init__(self, store):
        self.store = store
        self.indexes = MediaIndexes(store)
        self.thumbnail_cache = OrderedDict()
        self.thumbnail_lock = threading.RLock()
        self.thumbnail_bytes = 0

    def clear_cache(self, backup=None):
        self.indexes.clear(backup)
        path = str(self.store.path(backup)) if backup is not None else None
        with self.thumbnail_lock:
            for key in list(self.thumbnail_cache):
                if path is None or key[0] == path:
                    self.thumbnail_bytes -= len(self.thumbnail_cache.pop(key))

    def media_index(self, backup):
        return self.indexes.connection(backup)

    def read(
        self,
        backup,
        kind,
        query="",
        offset=0,
        limit=100,
        chat=None,
        filters=None,
        sort=None,
        order=None,
        dateFrom=None,
        dateTo=None,
        minDuration=None,
        maxDuration=None,
        mediaType=None,
        minSize=None,
        maxSize=None,
    ):
        limit = min(100000, max(1, int(limit)))
        offset = max(0, int(offset))
        options = dict(filters or {})
        for key, value in (
            ("dateFrom", dateFrom),
            ("dateTo", dateTo),
            ("minDuration", minDuration),
            ("maxDuration", maxDuration),
            ("mediaType", mediaType),
            ("minSize", minSize),
            ("maxSize", maxSize),
        ):
            if value not in (None, ""):
                options[key] = value
        if kind == "photos":
            return self.indexes.read(backup, query, offset, limit, options, sort, order)
        if kind in ("music", "watch", "health", "appdata"):
            return self.media(backup, kind, query, offset, limit)
        if kind not in data_queries.DATASETS:
            raise ValueError("Unknown data type.")
        suffix, tables, domains, paths = data_queries.DATASETS[kind]
        identity = None
        if kind == "safari":
            identity = lambda entry: (
                "safari" in entry["domain"].lower()
                or "/safari/" in "/" + entry["relativePath"].lower()
            )
        manager = (
            whatsapp_data.database(self.store, backup)
            if kind == "whatsapp"
            else self.store.database(
                backup,
                suffix,
                tables,
                domains,
                paths,
                lambda db: data_queries.validate_schema(db, kind),
                identity,
            )
        )
        try:
            with manager as db:
                try:
                    sql, columns, default_sort, default_order = data_queries.query(db, kind, chat)
                except ValueError as error:
                    raise DatasetUnavailable("unsupported", str(error)) from error
                rows, total = data_queries.paged(
                    db, sql, query, offset, limit, options, sort, order, default_sort, default_order
                )
                if kind == "contacts":
                    self._contacts(db, rows)
                if kind == "notes":
                    self._notes(db, rows)
                for row in rows:
                    if "rawDate" in row:
                        row["date"] = apple_date(row.pop("rawDate"))
                    if "rawEnd" in row:
                        row["end"] = apple_date(row.pop("rawEnd"))
                    if kind == "calendar":
                        row["start"] = row.get("date", "")
                    if kind == "calls":
                        row["detail"] = (
                            f"{int(row['duration'] or 0)} seconds · call type {row['type']}"
                        )
                    if kind == "messages" and chat is not None:
                        row["body"] = text_body(row.pop("text"), row.pop("attributed"))
                    if kind == "whatsapp" and chat is not None:
                        row["body"] = row.get("body") or "[Attachment]"
                return {
                    "rows": rows,
                    "total": total,
                    "columns": columns,
                    "available": True,
                    "availability": {"status": "available", "message": ""},
                }
        except DatasetUnavailable as error:
            message = error.args[0]
            if error.status == "missing":
                message = {
                    "safari": "Safari history is not included in this backup. History synced through iCloud may be absent from a computer backup."
                }.get(kind, message)
            return {
                "rows": [],
                "total": 0,
                "columns": ["name", "date"],
                "available": False,
                "message": message,
                "availability": {
                    "status": error.status,
                    "message": message,
                    "details": error.details,
                },
            }
        except sqlite3.OperationalError as error:
            if not any(text in str(error).lower() for text in ("no such table", "no such column")):
                raise
            message = "This backup uses a newer data format that Phosphor cannot read yet. The original files are available in Backup files."
            return {
                "rows": [],
                "total": 0,
                "columns": ["name", "date"],
                "available": False,
                "message": message,
                "availability": {"status": "unsupported", "message": message},
            }

    def _contacts(self, db, rows):
        ids = [row["id"] for row in rows]
        multi = {}
        if ids and {"record_id", "property", "value"} <= cols(db, "ABMultiValue"):
            for row in db.execute(
                "SELECT record_id,property,value FROM ABMultiValue WHERE record_id IN (SELECT value FROM json_each(?))",
                [json.dumps(ids)],
            ):
                if row["property"] in (3, 4):
                    multi.setdefault(row["record_id"], {"phones": [], "emails": []})[
                        "phones" if row["property"] == 3 else "emails"
                    ].append(row["value"] or "")
        for row in rows:
            row.update(multi.get(row["id"], {"phones": [], "emails": []}))
            row["name"] = (
                " ".join(x for x in (row["first"], row["last"]) if x)
                or row["organization"]
                or "Unnamed contact"
            )
            row["detail"] = " · ".join(row["phones"] + row["emails"])

    def _notes(self, db, rows):
        ids = [row["id"] for row in rows if not row.get("locked")]
        bodies = {}
        if ids and {"ZNOTE", "ZDATA"} <= cols(db, "ZICNOTEDATA"):
            for row in db.execute(
                "SELECT ZNOTE,substr(ZDATA,1,8388609) AS ZDATA FROM ZICNOTEDATA WHERE ZNOTE IN (SELECT value FROM json_each(?))",
                [json.dumps(ids)],
            ):
                text = decode_note_text(row["ZDATA"])
                if text is not None:
                    bodies[row["ZNOTE"]] = text
        for row in rows:
            if row.get("locked"):
                row["body"] = ""
                row["bodyStatus"] = "locked"
                row["previewMessage"] = (
                    "This note has its own password protection. Its content cannot be read using the backup password."
                )
            elif row["id"] in bodies:
                row["body"] = bodies[row["id"]]
                row["bodyStatus"] = "full"
            else:
                row["bodyStatus"] = "snippet" if row.get("body") else "unavailable"
                row["previewMessage"] = (
                    "Only the saved snippet is included or readable in this backup."
                    if row.get("body")
                    else "This note’s text is not included or uses an unsupported format."
                )

    def media(self, backup, kind, query, offset, limit):
        if kind == "photos":
            predicate = "(domain='CameraRollDomain' OR domain='MediaDomain') AND (lower(relativePath) GLOB '*.jpg' OR lower(relativePath) GLOB '*.jpeg' OR lower(relativePath) GLOB '*.png' OR lower(relativePath) GLOB '*.heic' OR lower(relativePath) GLOB '*.mov' OR lower(relativePath) GLOB '*.mp4')"
        elif kind == "music":
            predicate = "(lower(relativePath) GLOB '*.mp3' OR lower(relativePath) GLOB '*.m4a' OR lower(relativePath) GLOB '*.m4r' OR lower(relativePath) GLOB '*.wav')"
        elif kind == "watch":
            predicate = "(lower(relativePath) LIKE '%watch%' OR lower(domain) LIKE '%watch%')"
        elif kind == "health":
            predicate = "(lower(relativePath) LIKE '%health%' OR lower(domain) LIKE '%health%')"
        else:
            predicate = "domain LIKE 'AppDomain%'"
        with self.store.connection(backup) as db:
            where = f"flags=1 AND ({predicate}) AND relativePath LIKE ? ESCAPE '\\'"
            escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            args = ["%" + escaped + "%"]
            total = db.execute("SELECT COUNT(*) FROM Files WHERE " + where, args).fetchone()[0]
            rows = [
                dict(r)
                for r in db.execute(
                    "SELECT fileID AS id, relativePath AS path, domain FROM Files WHERE "
                    + where
                    + " ORDER BY relativePath LIMIT ? OFFSET ?",
                    [*args, limit, offset],
                )
            ]
        for row in rows:
            row["name"] = Path(row["path"]).name
            row["detail"] = row["domain"]
            row["video"] = Path(row["path"]).suffix.lower() in (".mov", ".mp4")
        return {"rows": rows, "total": total, "columns": ["name", "path", "domain"]}

    def thumbnail(self, backup, file):
        key = (str(self.store.path(backup)), self.store.generation(backup), file)
        with self.store.connection(backup):
            pass
        with self.thumbnail_lock:
            cached = self.thumbnail_cache.get(key)
            if cached is not None:
                self.thumbnail_cache.move_to_end(key)
                return cached
        from PIL import Image, ImageOps
        from pillow_heif import register_heif_opener

        register_heif_opener()
        entry = self.store.entries(backup, [file])
        if not entry:
            raise ValueError("Photo not found.")
        image = Image.open(io.BytesIO(self.store.bytes(backup, entry[0])))
        image = ImageOps.exif_transpose(image)
        image.thumbnail((400, 400))
        out = io.BytesIO()
        image.convert("RGB").save(out, "JPEG", quality=80)
        result = "data:image/jpeg;base64," + base64.b64encode(out.getvalue()).decode("ascii")
        with self.thumbnail_lock:
            old = self.thumbnail_cache.pop(key, None)
            if old is not None:
                self.thumbnail_bytes -= len(old)
            self.thumbnail_cache[key] = result
            self.thumbnail_bytes += len(result)
            while self.thumbnail_bytes > 16 * 1024 * 1024 or len(self.thumbnail_cache) > 384:
                self.thumbnail_bytes -= len(self.thumbnail_cache.popitem(last=False)[1])
        return result

    def export(
        self,
        backup,
        kind,
        destination,
        format="csv",
        ids=None,
        chat=None,
        query="",
        job=None,
        filters=None,
        sort=None,
        order=None,
        dateFrom=None,
        dateTo=None,
        minDuration=None,
        maxDuration=None,
    ):
        rows = []
        offset = 0
        options = {
            "filters": filters,
            "sort": sort,
            "order": order,
            "dateFrom": dateFrom,
            "dateTo": dateTo,
            "minDuration": minDuration,
            "maxDuration": maxDuration,
        }
        selected_ids = {str(i) for i in ids} if ids else None
        while True:
            if job:
                job.check()
            page = self.read(backup, kind, query, offset, 1000, chat, **options)
            rows.extend(r for r in page["rows"] if not selected_ids or str(r["id"]) in selected_ids)
            offset += len(page["rows"])
            if offset >= page["total"] or not page["rows"]:
                break
        if kind in ("messages", "whatsapp") and chat is None:
            messages = []
            for conversation in rows:
                page_offset = 0
                while True:
                    if job:
                        job.check()
                    page = self.read(
                        backup,
                        kind,
                        offset=page_offset,
                        limit=1000,
                        chat=conversation["id"],
                        **options,
                    )
                    messages.extend(
                        {**m, "conversation": conversation["name"]} for m in page["rows"]
                    )
                    page_offset += len(page["rows"])
                    if page_offset >= page["total"] or not page["rows"]:
                        break
            rows = messages
        if format == "json":
            data = json.dumps(rows, ensure_ascii=False, indent=2).encode("utf-8")
        elif format == "html":
            parts = [
                '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Phosphor export</title><style>body{font:15px system-ui;background:#f5f6f2;max-width:850px;margin:40px auto;padding:20px}article{background:white;padding:18px;border-radius:16px;margin:14px 0;white-space:pre-wrap;overflow-wrap:anywhere}.out{background:#e6efcc;margin-left:15%}small{color:#667}</style></head><body><h1>Phosphor · '
                + html.escape(kind.title())
                + "</h1>"
            ]
            for row in rows:
                parts.append(
                    '<article class="'
                    + ("out" if row.get("outgoing") else "")
                    + '"><small>'
                    + html.escape(
                        " · ".join(
                            str(row.get(k) or "")
                            for k in ("conversation", "name", "sender", "date")
                        )
                    )
                    + "</small><p>"
                    + html.escape(str(row.get("body") or row.get("detail") or row))
                    + "</p></article>"
                )
            data = ("".join(parts) + "</body></html>").encode("utf-8")
        elif format == "txt":
            data = "\n\n".join(
                " · ".join(str(r.get(k) or "") for k in ("conversation", "name", "date", "sender"))
                + "\n"
                + str(r.get("body") or r.get("detail") or r)
                for r in rows
            ).encode("utf-8")
        elif format == "vcf" and kind == "contacts":
            lines = []
            for r in rows:
                esc = (
                    lambda x: str(x or "")
                    .replace("\\", "\\\\")
                    .replace("\n", "\\n")
                    .replace(";", "\\;")
                    .replace(",", "\\,")
                    .replace("\r", "")
                )
                lines.extend(
                    [
                        "BEGIN:VCARD",
                        "VERSION:3.0",
                        "FN:" + esc(r["name"]),
                        "N:" + esc(r["last"]) + ";" + esc(r["first"]) + ";;;",
                        "ORG:" + esc(r["organization"]),
                    ]
                )
                lines.extend("TEL;TYPE=CELL:" + esc(p) for p in r["phones"])
                lines.extend("EMAIL:" + esc(e) for e in r["emails"])
                lines.append("END:VCARD")
            data = ("\r\n".join(lines) + "\r\n").encode("utf-8")
        elif format == "ics" and kind == "calendar":
            lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Phosphor Windows//EN"]
            esc = (
                lambda x: str(x or "")
                .replace("\\", "\\\\")
                .replace("\n", "\\n")
                .replace(";", "\\;")
                .replace(",", "\\,")
                .replace("\r", "")
            )
            stamp = lambda x: datetime.fromisoformat(x).strftime("%Y%m%dT%H%M%SZ")
            for r in rows:
                if not r.get("date"):
                    continue
                end = r.get("end") or (
                    (datetime.fromisoformat(r["date"]) + timedelta(days=1)).isoformat()
                    if r.get("allDay")
                    else r["date"]
                )
                lines.extend(
                    [
                        "BEGIN:VEVENT",
                        f"UID:phosphor-{r['id']}@local",
                        "DTSTAMP:" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
                        "DTSTART"
                        + (
                            ";VALUE=DATE:" + datetime.fromisoformat(r["date"]).strftime("%Y%m%d")
                            if r.get("allDay")
                            else ":" + stamp(r["date"])
                        ),
                        "DTEND"
                        + (
                            ";VALUE=DATE:" + datetime.fromisoformat(end).strftime("%Y%m%d")
                            if r.get("allDay")
                            else ":" + stamp(end)
                        ),
                        "SUMMARY:" + esc(r["name"]),
                        "DESCRIPTION:" + esc(r.get("body")),
                        "END:VEVENT",
                    ]
                )
            lines.append("END:VCALENDAR")
            # Fold by UTF-8 octets, without breaking a multibyte character (RFC 5545).
            folded = []
            for line in lines:
                chunk = ""
                for char in line:
                    if len((chunk + char).encode("utf-8")) > 75:
                        folded.append(chunk)
                        chunk = " " + char
                    else:
                        chunk += char
                folded.append(chunk)
            data = ("\r\n".join(folded) + "\r\n").encode("utf-8")
        elif format == "csv":
            out = io.StringIO(newline="")
            fields = list(dict.fromkeys(k for row in rows for k in row)) or ["name"]
            writer = csv.DictWriter(out, fieldnames=fields)
            writer.writeheader()
            for row in rows:
                cleaned = {}
                for k, v in row.items():
                    value = (
                        " | ".join(map(str, v))
                        if isinstance(v, list)
                        else str(v) if v is not None else ""
                    )
                    cleaned[k] = (
                        "'" + value
                        if value.lstrip().startswith(("=", "+", "-", "@", "\t", "\r"))
                        else value
                    )
                writer.writerow(cleaned)
            data = b"\xef\xbb\xbf" + out.getvalue().encode("utf-8")
        else:
            raise ValueError("Unsupported export format.")
        if job:
            job.check()
        return {"count": len(rows), "output": publish_bytes(destination, data)}
