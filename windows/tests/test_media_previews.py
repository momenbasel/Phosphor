import io
import struct
from types import SimpleNamespace

import pytest
from PIL import Image

from media import image_preview, _tiff_raw_preflight


def synthetic_dng(path):
    """Original minimal, uncompressed RGGB fixture; no camera/user files."""
    width = height = 64
    tags = [
        (254, 4, [0]),
        (256, 4, [width]),
        (257, 4, [height]),
        (258, 3, [16]),
        (259, 3, [1]),
        (262, 3, [32803]),
        (271, 2, b"Phosphor\0"),
        (272, 2, b"Synthetic\0"),
        (273, 4, [0]),
        (277, 3, [1]),
        (278, 4, [height]),
        (279, 4, [width * height * 2]),
        (284, 3, [1]),
        (33421, 3, [2, 2]),
        (33422, 1, bytes([0, 1, 1, 2])),
        (50706, 1, bytes([1, 4, 0, 0])),
        (50707, 1, bytes([1, 1, 0, 0])),
        (50708, 2, b"Phosphor Synthetic DNG\0"),
        (50714, 5, [(0, 1)]),
        (50717, 4, [65535]),
        (50721, 10, [(1, 1), (0, 1), (0, 1), (0, 1), (1, 1), (0, 1), (0, 1), (0, 1), (1, 1)]),
        (50728, 5, [(1, 1), (1, 1), (1, 1)]),
        (50778, 3, [21]),
    ]
    tags.sort()
    offset = 8 + 2 + 12 * len(tags) + 4
    extra = bytearray()
    records = []
    for tag, kind, value in tags:
        count = len(value)
        if kind in (1, 2):
            data = value
        elif kind == 3:
            data = struct.pack("<" + "H" * count, *value)
        elif kind == 4:
            data = struct.pack("<" + "I" * count, *value)
        else:
            data = b"".join(struct.pack("<ii" if kind == 10 else "<II", *pair) for pair in value)
        if len(data) <= 4:
            payload = data.ljust(4, b"\0")
        else:
            payload = struct.pack("<I", offset + len(extra))
            extra.extend(data)
            if len(extra) % 2:
                extra.append(0)
        records.append((tag, kind, count, payload))
    pixels = offset + len(extra)
    records = [
        (tag, kind, count, struct.pack("<I", pixels) if tag == 273 else payload)
        for tag, kind, count, payload in records
    ]
    header = b"II" + struct.pack("<HIH", 42, 8, len(tags))
    entries = b"".join(
        struct.pack("<HHI", tag, kind, count) + payload for tag, kind, count, payload in records
    )
    raw = b"".join(
        struct.pack("<H", 1000 + 500 * x + 200 * y) for y in range(height) for x in range(width)
    )
    path.write_bytes(header + entries + bytes(4) + extra + raw)


def test_raster_preview_is_bounded_jpeg_and_preserves_original(tmp_path):
    source, target = tmp_path / "source.png", tmp_path / "preview.jpg"
    Image.new("RGBA", (1400, 800), (255, 0, 0, 0)).save(source)
    original = source.read_bytes()
    result = image_preview(source, target, max_edge=320)
    with Image.open(target) as image:
        assert image.format == "JPEG" and image.size == (320, 183)
        assert image.getpixel((0, 0)) == (255, 255, 255)
    assert result["raw"] is False
    assert source.read_bytes() == original


def test_real_libraw_decodes_original_synthetic_dng(tmp_path):
    source, target = tmp_path / "synthetic.dng", tmp_path / "preview.jpg"
    synthetic_dng(source)
    result = image_preview(source, target, max_edge=320)
    with Image.open(target) as image:
        assert image.format == "JPEG" and 0 < image.width <= 320 and 0 < image.height <= 320
    assert result["raw"] is True


def test_raw_header_limit_prevents_unpack(tmp_path, monkeypatch):
    import rawpy

    source = tmp_path / "fake.dng"
    source.write_bytes(b"synthetic")
    calls = []

    class Raw:
        sizes = SimpleNamespace(raw_width=100000, raw_height=100000, width=100000, height=100000)

        def open_file(self, path):
            calls.append("header")

        def unpack(self):
            pytest.fail("Oversized RAW must not allocate pixels")

        def close(self):
            calls.append("close")

    monkeypatch.setattr(rawpy, "RawPy", Raw)
    with pytest.raises(ValueError, match="120 megapixel"):
        image_preview(source, tmp_path / "target.jpg")
    assert calls == ["header", "close"]


def test_bad_raw_reports_in_app_decode_error(tmp_path):
    source = tmp_path / "bad.dng"
    source.write_bytes(b"not RAW")
    with pytest.raises(ValueError, match="could not be decoded"):
        image_preview(source, tmp_path / "target.jpg")


def test_disguised_postscript_never_runs_external_renderer(tmp_path, monkeypatch):
    from PIL import EpsImagePlugin

    source = tmp_path / "disguised.png"
    source.write_text("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\nshowpage\n")
    monkeypatch.setattr(
        EpsImagePlugin,
        "Ghostscript",
        lambda *_a, **_k: pytest.fail("Never execute an external renderer"),
    )
    with pytest.raises(ValueError, match="safe in-app"):
        image_preview(source, tmp_path / "target.jpg")


@pytest.mark.parametrize(
    "kind,count,payload",
    [
        (11, 1, struct.pack("<f", float("nan"))),
        (11, 1, struct.pack("<f", float("inf"))),
        (11, 1, struct.pack("<f", 0.0)),
        (12, 1, struct.pack("<I", 40)),
        (9, 1, struct.pack("<i", -1)),
        (4, 2, struct.pack("<I", 40)),
        (4, 0, b"\0" * 4),
        (4, 1, struct.pack("<I", 0xE3000001)),
    ],
)
def test_invalid_new_subfile_type_never_reaches_native_decoder(
    tmp_path, monkeypatch, kind, count, payload
):
    import rawpy

    source = tmp_path / "invalid.dng"
    source.write_bytes(
        b"II"
        + struct.pack("<HIH", 42, 8, 1)
        + struct.pack("<HHI", 254, kind, count)
        + payload
        + bytes(50)
    )
    monkeypatch.setattr(
        rawpy,
        "RawPy",
        lambda: pytest.fail("Invalid metadata must be rejected before native parser construction"),
    )
    with pytest.raises(ValueError, match="NewSubfileType"):
        image_preview(source, tmp_path / "preview.jpg")


def test_ifd_cycles_bounds_and_large_counts_are_rejected(tmp_path):
    source = tmp_path / "malformed.dng"
    header = b"II" + struct.pack("<HI", 42, 8)
    for root in (
        struct.pack("<HI", 0, 8),
        struct.pack("<HHHIII", 1, 330, 4, 1, 0xFFFFFFFF, 0),
        struct.pack("<H", 65535),
        struct.pack("<HHHIII", 1, 330, 4, 513, 26, 0),
    ):
        source.write_bytes(header + root)
        with pytest.raises(ValueError, match="TIFF metadata"):
            _tiff_raw_preflight(source)
