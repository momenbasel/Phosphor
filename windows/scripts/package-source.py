"""Create a reviewable source archive without build caches or personal profiles."""

import os
import json
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
version = json.loads((root / "windows" / "package.json").read_text("utf-8"))["version"]
output = root / "windows" / "release" / f"Phosphor-{version}-Source.zip"
output.parent.mkdir(parents=True, exist_ok=True)
skip = {
    ".git",
    ".venv",
    "node_modules",
    ".build",
    "backend-build",
    "backend-dist",
    "release",
    "dist",
    ".test-profile",
    "test-output",
    "__pycache__",
    ".pytest_cache",
}
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for folder, directories, files in os.walk(root):
        directories[:] = sorted(
            d for d in directories if d not in skip and not d.startswith(".test-")
        )
        for name in sorted(files):
            path = Path(folder) / name
            if path.suffix in (".pyc", ".log"):
                continue
            archive.write(path, "Phosphor/" + path.relative_to(root).as_posix())
print(output)
