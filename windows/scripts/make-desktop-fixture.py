"""Synthetic media for the desktop's internal startup/protocol test."""

import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tests"))
from conftest import create_fixture

backup, photo = create_fixture(Path(sys.argv[1]))
files = Path(sys.argv[1]) / "files"
files.mkdir()
parts = [b"%PDF-1.7\n"]
offsets = [0]
objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    None,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
text = "BT /F1 12 Tf 20 50 Td (Phosphor PDF fixture) Tj ET"
objects[3] = f"<< /Length {len(text)} >>\nstream\n{text}\nendstream"
for number, body in enumerate(objects, 1):
    offsets.append(sum(map(len, parts)))
    parts.append(f"{number} 0 obj\n{body}\nendobj\n".encode())
xref = sum(map(len, parts))
parts.append(
    (
        "xref\n0 6\n0000000000 65535 f \n"
        + "".join(f"{offset:010} 00000 n \n" for offset in offsets[1:])
        + f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
    ).encode()
)
(files / "fixture.pdf").write_bytes(b"".join(parts))
chat = files / "WhatsApp fixture.txt"
chat.write_text(
    "[13/10/2026, 10:00:00] Alex: Phosphor WhatsApp fixture 🦊\nSecond line\n[13/10/2026, 10:01:00] You: Reply from fixture\n",
    encoding="utf-8",
)
print(
    json.dumps(
        {
            "backup": str(backup.resolve()),
            "photo": photo,
            "files": str(files.resolve()),
            "chat": str(chat.resolve()),
        }
    )
)
