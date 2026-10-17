"""Schema-selected SQL for optional iOS datasets, with filtering before paging."""

from datetime import datetime, timedelta, timezone

DATASETS = {
    "messages": (
        "sms.db",
        ("chat", "message", "chat_message_join"),
        ("HomeDomain",),
        ("Library/SMS/",),
    ),
    "whatsapp": (("ChatStorage.sqlite", "ChatStorage.db"), ("ZWACHATSESSION",), ("whatsapp",), ()),
    "contacts": ("AddressBook.sqlitedb", ("ABPerson",), ("HomeDomain",), ("Library/AddressBook/",)),
    "calendar": (
        ("Calendar.sqlitedb", "Calendar.sqlite"),
        ("CalendarItem",),
        ("HomeDomain",),
        ("Library/Calendar/",),
    ),
    "notes": (
        "NoteStore.sqlite",
        ("ZICCLOUDSYNCINGOBJECT",),
        ("com.apple.notes", "HomeDomain"),
        ("Library/Notes/",),
    ),
    "calls": (
        "CallHistory.storedata",
        ("ZCALLRECORD",),
        ("HomeDomain",),
        ("Library/CallHistoryDB/",),
    ),
    "safari": (
        "History.db",
        ("history_items",),
        ("HomeDomain", "com.apple.mobilesafari"),
        ("Library/Safari/",),
    ),
}


def columns(db, table):
    return {r["name"] for r in db.execute(f'PRAGMA table_info("{table}")')}


def field(available, candidates, alias, default="NULL", prefix=""):
    if isinstance(candidates, str):
        candidates = [candidates]
    name = next((c for c in candidates if c in available), None)
    return f'{prefix}"{name}" AS "{alias}"' if name else f'{default} AS "{alias}"'


def date_bound(value, end=False):
    if value in (None, ""):
        return None
    if not isinstance(value, str):
        raise ValueError("Choose a valid date range.")
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=timezone.utc)
        if end and len(value) == 10:
            stamp += timedelta(days=1)
        return stamp.timestamp()
    except (ValueError, OverflowError, OSError):
        raise ValueError("Choose a valid date range.")


def validate_schema(db, kind):
    requirements = {
        "messages": {
            "chat": ("chat_identifier",),
            "message": ("date", "is_from_me", "handle_id", "text"),
            "chat_message_join": ("chat_id", "message_id"),
        },
        "whatsapp": {"ZWACHATSESSION": ("Z_PK",)},
        "contacts": {},
        "calendar": {},
        "notes": {"ZICCLOUDSYNCINGOBJECT": ("Z_PK",)},
        "calls": {"ZCALLRECORD": ("Z_PK",)},
        "safari": {"history_items": ("id", "url")},
    }
    return all(
        set(required) <= columns(db, table) for table, required in requirements[kind].items()
    )


def query(db, kind, chat=None):
    c = columns(
        db,
        {
            "messages": "chat",
            "whatsapp": "ZWACHATSESSION",
            "contacts": "ABPerson",
            "calendar": "CalendarItem",
            "notes": "ZICCLOUDSYNCINGOBJECT",
            "calls": "ZCALLRECORD",
            "safari": "history_items",
        }[kind],
    )
    if kind == "messages":
        if chat is not None:
            m = columns(db, "message")
            h = "LEFT JOIN handle h ON m.handle_id=h.ROWID" if columns(db, "handle") else ""
            sender = "h.id" if h and "id" in columns(db, "handle") else "''"
            return (
                "SELECT m.ROWID AS id,m.date AS rawDate,m.is_from_me AS outgoing,"
                + sender
                + " AS sender,m.text AS text,"
                + ("m.attributedBody" if "attributedBody" in m else "NULL")
                + " AS attributed FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID "
                + h
                + " WHERE cm.chat_id="
                + str(int(chat)),
                ["date", "sender", "body"],
                "rawDate",
                "asc",
            )
        display = "c.display_name" if "display_name" in c else "''"
        return (
            f"SELECT c.ROWID AS id,COALESCE(NULLIF({display},''),c.chat_identifier) AS name,c.chat_identifier AS detail,COUNT(cm.message_id) AS count,MAX(m.date) AS rawDate FROM chat c LEFT JOIN chat_message_join cm ON cm.chat_id=c.ROWID LEFT JOIN message m ON m.ROWID=cm.message_id GROUP BY c.ROWID",
            ["name", "detail", "date"],
            "rawDate",
            "desc",
        )
    if kind == "whatsapp":
        if chat is not None:
            c = columns(db, "ZWAMESSAGE")
            if not {"Z_PK", "ZCHATSESSION"} <= c:
                raise ValueError("WhatsApp message schema is unsupported.")
            fields = [
                "Z_PK AS id",
                field(c, "ZTEXT", "body", "'[Attachment]'"),
                field(c, "ZMESSAGEDATE", "rawDate"),
                field(c, "ZISFROMME", "outgoing", "0"),
                field(c, "ZFROMJID", "sender", "''"),
            ]
            return (
                "SELECT "
                + ",".join(fields)
                + " FROM ZWAMESSAGE WHERE ZCHATSESSION="
                + str(int(chat)),
                ["date", "sender", "body"],
                "rawDate",
                "asc",
            )
        name = (
            "COALESCE(NULLIF(ZPARTNERNAME,''),ZCONTACTJID)"
            if {"ZPARTNERNAME", "ZCONTACTJID"} <= c
            else "ZCONTACTJID" if "ZCONTACTJID" in c else "'WhatsApp conversation'"
        )
        fields = [
            "Z_PK AS id",
            name + " AS name",
            field(c, "ZCONTACTJID", "detail", "''"),
            field(c, "ZMESSAGECOUNTER", "count", "0"),
            field(c, "ZLASTMESSAGEDATE", "rawDate"),
        ]
        return (
            "SELECT " + ",".join(fields) + " FROM ZWACHATSESSION",
            ["name", "detail", "date"],
            "rawDate",
            "desc",
        )
    if kind == "contacts":
        details = (
            "(SELECT GROUP_CONCAT(mv.value, ' · ') FROM ABMultiValue mv WHERE mv.record_id=p.ROWID AND mv.property IN (3,4)) AS detail"
            if {"record_id", "property", "value"} <= columns(db, "ABMultiValue")
            else "'' AS detail"
        )
        fields = [
            "p.ROWID AS id",
            field(c, "First", "first", "''", "p."),
            field(c, "Last", "last", "''", "p."),
            field(c, "Organization", "organization", "''", "p."),
            details,
        ]
        first = "COALESCE(p.First,'')" if "First" in c else "''"
        last = "COALESCE(p.Last,'')" if "Last" in c else "''"
        fields.append("trim(" + first + "||' '||" + last + ") AS name")
        return "SELECT " + ",".join(fields) + " FROM ABPerson p", ["name", "detail"], "id", "asc"
    if kind == "calendar":
        fields = [
            "ROWID AS id",
            field(c, "summary", "name", "'Untitled event'"),
            field(c, "start_date", "rawDate"),
            field(c, "end_date", "rawEnd"),
            field(c, "all_day", "allDay", "0"),
            field(c, "description", "body", "''"),
            field(c, ["location", "location_string"], "location", "''"),
        ]
        return (
            "SELECT " + ",".join(fields) + " FROM CalendarItem",
            ["name", "date", "end", "location"],
            "rawDate",
            "desc",
        )
    if kind == "notes":
        title = next((n for n in ("ZTITLE1", "ZTITLE") if n in c), None)
        if not title:
            raise ValueError("Notes title schema is unsupported.")
        fields = [
            "Z_PK AS id",
            field(c, title, "name", "'Untitled note'"),
            field(c, "ZSNIPPET", "body", "''"),
            field(c, ["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"], "rawDate"),
            field(c, "ZISPASSWORDPROTECTED", "locked", "0"),
        ]
        return (
            "SELECT "
            + ",".join(fields)
            + " FROM ZICCLOUDSYNCINGOBJECT WHERE "
            + title
            + " IS NOT NULL",
            ["name", "date"],
            "rawDate",
            "desc",
        )
    if kind == "calls":
        fields = [
            "Z_PK AS id",
            field(c, "ZADDRESS", "name", "''"),
            field(c, "ZDATE", "rawDate"),
            field(c, "ZDURATION", "duration", "0"),
            field(c, "ZCALLTYPE", "type", "0"),
        ]
        return (
            "SELECT " + ",".join(fields) + " FROM ZCALLRECORD",
            ["name", "date", "duration"],
            "rawDate",
            "desc",
        )
    visits = columns(db, "history_visits")
    title = "COALESCE(NULLIF(hi.title,''),hi.url)" if "title" in c else "hi.url"
    count = (
        "hi.visit_count"
        if "visit_count" in c
        else "COUNT(hv.history_item)" if {"history_item", "visit_time"} <= visits else "0"
    )
    dated = {"history_item", "visit_time"} <= visits
    sql = (
        "SELECT hi.id,"
        + title
        + " AS name,hi.url AS detail,"
        + count
        + " AS count,"
        + ("MAX(hv.visit_time)" if dated else "NULL")
        + " AS rawDate FROM history_items hi"
    )
    if dated:
        sql += " LEFT JOIN history_visits hv ON hv.history_item=hi.id GROUP BY hi.id"
    return sql, ["name", "detail", "date"], "rawDate", "desc"


def paged(db, sql, query_text, offset, limit, filters, sort, order, default_sort, default_order):
    names = [d[0] for d in db.execute(sql + " LIMIT 0").description]
    predicates = []
    args = []
    if query_text:
        searchable = [
            n for n in names if n in ("name", "detail", "body", "first", "last", "organization")
        ]
        if searchable:
            escaped = str(query_text).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            predicates.append(
                "("
                + " OR ".join(f"CAST(q.\"{n}\" AS TEXT) LIKE ? ESCAPE '\\'" for n in searchable)
                + ")"
            )
            args += ["%" + escaped + "%"] * len(searchable)
    if "rawDate" in names:
        timestamp = "(CASE WHEN ABS(q.rawDate)>1000000000000 THEN q.rawDate/1000000000.0 ELSE q.rawDate END)+978307200"
        start = date_bound(filters.get("dateFrom"))
        end = date_bound(filters.get("dateTo"), True)
        floating_calendar = {"allDay", "rawEnd"} <= set(names)
        day_start = date_bound(filters.get("dayFrom")) if floating_calendar else None
        day_end = date_bound(filters.get("dayTo")) if floating_calendar else None
        # Calendar month mode includes events spanning the beginning of a month.
        if start is not None:
            expression = (
                "COALESCE(q.rawEnd,q.rawDate)+978307200" if "rawEnd" in names else timestamp
            )
            if day_start is not None:
                # All-day dates are floating calendar days represented at UTC
                # midnight, whereas timed events need the viewer's local-month
                # instant bounds. All-day end dates are exclusive.
                predicates.append(
                    "(CASE WHEN COALESCE(q.allDay,0)<>0 THEN COALESCE(q.rawEnd,q.rawDate+86400)+978307200>? ELSE "
                    + expression
                    + ">=? END)"
                )
                args.extend([day_start, start])
            else:
                predicates.append(expression + ">=?")
                args.append(start)
        if end is not None:
            if day_end is not None:
                predicates.append(
                    "(CASE WHEN COALESCE(q.allDay,0)<>0 THEN "
                    + timestamp
                    + "<? ELSE "
                    + timestamp
                    + "<? END)"
                )
                args.extend([day_end, end])
            else:
                predicates.append(timestamp + "<?")
                args.append(end)
    if "duration" in names:
        for key, operator in (("minDuration", ">="), ("maxDuration", "<=")):
            if filters.get(key) not in (None, ""):
                value = float(filters[key])
                if value < 0:
                    raise ValueError("Call duration cannot be negative.")
                predicates.append("q.duration" + operator + "?")
                args.append(value)
    where = " WHERE " + " AND ".join(predicates) if predicates else ""
    key = sort.get("key") if isinstance(sort, dict) else sort
    direction = sort.get("direction", order) if isinstance(sort, dict) else order
    key = {
        "date": "rawDate",
        "end": "rawEnd",
        "name": "name",
        "duration": "duration",
        "count": "count",
    }.get(key, key) or default_sort
    if key not in names:
        key = default_sort
    direction = "ASC" if str(direction or default_order).lower() == "asc" else "DESC"
    total = db.execute("SELECT COUNT(*) FROM (" + sql + ") q" + where, args).fetchone()[0]
    rows = [
        dict(r)
        for r in db.execute(
            "SELECT * FROM ("
            + sql
            + ") q"
            + where
            + f' ORDER BY q."{key}" {direction},q.id {direction} LIMIT ? OFFSET ?',
            [*args, limit, offset],
        )
    ]
    return rows, total
