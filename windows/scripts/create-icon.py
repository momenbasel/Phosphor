"""Derive the Windows icons from the macOS app icon so both editions share one mark."""

from PIL import Image
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root.parent / "Resources" / "AppIcon.icns"
root.joinpath("assets").mkdir(exist_ok=True)
# Pillow opens an ICNS file at its largest (1024 px) representation.
with Image.open(source) as icon:
    image = icon.convert("RGBA")
image.resize((512, 512), Image.LANCZOS).save(root / "assets" / "icon.png")
image.save(
    root / "assets" / "icon.ico",
    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
