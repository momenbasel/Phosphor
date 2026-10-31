"""Bounded device stream history and explicitly saved local transcripts."""

import json
import codecs
import threading
import uuid
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from backup import publish_bytes


class ConsoleStore:
    def __init__(self, data):
        self.data = Path(data)
        self.guard = threading.RLock()
        self.lines = deque()
        self.line_bytes = 0
        self.registry = self.data / "console-history.json"
        try:
            self.saved = json.loads(self.registry.read_text("utf-8"))
        except (OSError, ValueError):
            self.saved = []
        if not isinstance(self.saved, list):
            self.saved = []

    def append(self, line):
        line = str(line)[:20000]
        with self.guard:
            self.lines.append(line)
            self.line_bytes += len(line.encode("utf-8")) + 1
            while len(self.lines) > 10000 or self.line_bytes > 8 * 1024 * 1024:
                self.line_bytes -= len(self.lines.popleft().encode("utf-8")) + 1

    def read(self, limit=2000):
        with self.guard:
            return list(self.lines)[-min(10000, max(1, int(limit))) :]

    def clear(self):
        with self.guard:
            self.lines.clear()
            self.line_bytes = 0
        return True

    def save(self, path=None):
        with self.guard:
            if not self.lines:
                raise ValueError("There are no console lines to save.")
            text = "\n".join(self.lines) + "\n"
        if len(text.encode("utf-8")) > 20 * 1024 * 1024:
            raise ValueError(
                "This transcript exceeds the 20 MB limit. Clear the stream and save a shorter segment."
            )
        now = datetime.now(timezone.utc)
        identity = uuid.uuid4().hex
        target = (
            Path(path)
            if path
            else self.data
            / "ConsoleLogs"
            / ("Device-console-" + now.strftime("%Y-%m-%d_%H-%M-%S") + "-" + identity[:6] + ".txt")
        )
        if target.suffix.lower() != ".txt":
            raise ValueError("Save the device console as a .txt file.")
        target = Path(publish_bytes(target, text.encode("utf-8")))
        row = {
            "id": identity,
            "name": target.name,
            "path": str(target.resolve()),
            "bytes": target.stat().st_size,
            "date": now.isoformat(),
            "lines": text.count("\n"),
        }
        with self.guard:
            self.saved = [row, *self.saved][:1000]
            self.data.mkdir(parents=True, exist_ok=True)
            stage = self.registry.with_suffix(".tmp")
            stage.write_text(json.dumps(self.saved, indent=2), "utf-8")
            stage.replace(self.registry)
        return row

    def list(self):
        with self.guard:
            rows = [dict(row) for row in self.saved if isinstance(row, dict) and row.get("id")]
        for row in rows:
            row["missing"] = not Path(row.get("path", "")).is_file()
        return rows

    def open(self, id):
        with self.guard:
            row = next((row for row in self.saved if row.get("id") == id), None)
        if not row:
            raise ValueError("Choose a saved transcript first.")
        target = Path(row["path"])
        if not target.is_file() or target.is_symlink():
            raise ValueError(
                "The saved transcript is no longer available at its original location."
            )
        with target.open("rb") as stream:
            data = stream.read(1024 * 1024 + 1)
        truncated = len(data) > 1024 * 1024
        text = codecs.getincrementaldecoder("utf-8")("replace").decode(
            data[: 1024 * 1024], final=not truncated
        )
        return {**row, "text": text, "truncated": truncated}
