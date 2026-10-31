"""Native Windows replacements for macOS sips and afconvert."""

import io
import os
from pathlib import Path
from backup import publish_bytes, safe_component

RAW_SUFFIXES = frozenset(
    {
        ".dng",
        ".nef",
        ".nrw",
        ".cr2",
        ".cr3",
        ".arw",
        ".sr2",
        ".srf",
        ".rw2",
        ".orf",
        ".raf",
        ".pef",
        ".srw",
        ".raw",
        ".rwl",
        ".3fr",
        ".erf",
        ".kdc",
        ".mos",
        ".mrw",
        ".x3f",
    }
)
MAX_PREVIEW_SOURCE_BYTES = 256 * 1024 * 1024
MAX_PREVIEW_PIXELS = 120_000_000
MAX_PREVIEW_EDGE = 4096


def _tiff_raw_preflight(source):
    """Validate reachable TIFF directory metadata before LibRaw's native parser.

    NewSubfileType is LONG/count=1 in TIFF. LibRaw 0.22.1 narrows arbitrary
    getreal() values to signed int; reject malformed variants before that cast.
    This guard covers TIFF containers, not every proprietary RAW parser.
    """
    import struct

    size = Path(source).stat().st_size
    maximum_read = 8 * 1024 * 1024
    read_bytes = 0
    problem = "This RAW file contains malformed or excessively complex TIFF metadata and cannot be previewed safely."
    with Path(source).open("rb") as stream:

        def read(offset, length):
            nonlocal read_bytes
            if (
                offset < 0
                or length < 0
                or offset + length > size
                or read_bytes + length > maximum_read
            ):
                raise ValueError(problem)
            stream.seek(offset)
            data = stream.read(length)
            if len(data) != length:
                raise ValueError(problem)
            read_bytes += length
            return data

        if size < 4:
            return
        header = read(0, 4)
        if header[:2] not in (b"II", b"MM"):
            return
        order = "<" if header[:2] == b"II" else ">"
        magic = struct.unpack(order + "H", header[2:])[0]
        if magic not in (42, 43, 85, 0x4F52, 0x5352):
            return
        big = magic == 43
        if big:
            offset_width, reserved, first = struct.unpack(order + "HHQ", read(4, 12))
            if offset_width != 8 or reserved:
                raise ValueError(problem)
            header_size, count_width, entry_width, value_width = 16, 8, 20, 8
        else:
            first = struct.unpack(order + "I", read(4, 4))[0]
            header_size, count_width, entry_width, value_width = 8, 2, 12, 4
        count_code, offset_code = ("Q", "Q") if big else ("H", "I")
        # Each path remembers ancestors: shared references are permitted,
        # actual cycles are rejected rather than passed into the native parser.
        pending = [(first, 0, frozenset())] if first else []
        visited = set()
        entries_seen = 0
        while pending:
            offset, depth, ancestors = pending.pop()
            if offset in ancestors or depth > 64 or offset < header_size:
                raise ValueError(problem)
            if offset in visited:
                continue
            visited.add(offset)
            if len(visited) > 512:
                raise ValueError(problem)
            count = struct.unpack(order + count_code, read(offset, count_width))[0]
            entries_seen += count
            if count > 4096 or entries_seen > 65536:
                raise ValueError(problem)
            table = read(offset + count_width, count * entry_width + value_width)
            branches = []
            for index in range(count):
                entry = table[index * entry_width : (index + 1) * entry_width]
                tag, kind = struct.unpack(order + "HH", entry[:4])
                length = struct.unpack(order + ("Q" if big else "I"), entry[4 : 12 if big else 8])[
                    0
                ]
                value = entry[12 if big else 8 :]
                if tag == 254:
                    if kind != 4 or length != 1:
                        raise ValueError(
                            "This RAW file has an invalid TIFF NewSubfileType field. A single unsigned LONG is required."
                        )
                    number = struct.unpack(order + "I", value[:4])[0]
                    if number > 0x7FFFFFFF:
                        raise ValueError(
                            "This RAW file has an out-of-range TIFF NewSubfileType value and cannot be previewed safely."
                        )
                if tag not in (330, 34665, 34853, 40965):
                    continue
                # SubIFDs may contain an array; Exif/GPS/interoperability
                # directory pointers each contain exactly one offset.
                widths = {4: 4, 13: 4, 16: 8, 18: 8}
                width = widths.get(kind)
                if (
                    not width
                    or not 1 <= length <= 512
                    or tag != 330
                    and length != 1
                    or not big
                    and width != 4
                ):
                    raise ValueError(problem)
                amount = width * length
                if amount <= value_width:
                    values = value[:amount]
                else:
                    location = struct.unpack(order + offset_code, value)[0]
                    values = read(location, amount)
                branches.extend(
                    struct.unpack(order + ("I" if width == 4 else "Q") * length, values)
                )
            next_offset = struct.unpack(order + offset_code, table[count * entry_width :])[0]
            branches.append(next_offset)
            following_ancestors = ancestors | {offset}
            pending.extend(
                (branch, depth + 1, following_ancestors) for branch in branches if branch
            )
            if len(pending) > 1024:
                raise ValueError(problem)


_raw_decoder_error = None


def initialize_raw_decoder():
    """Warm native RAW dependencies on the engine main thread, before RPC input."""
    global _raw_decoder_error
    try:
        import rawpy
    except Exception:
        # Do not retry a broken native import from a request thread.
        _raw_decoder_error = (
            "The RAW decoder could not be initialized. Repair or reinstall Phosphor "
            "to enable DNG and camera RAW previews."
        )
        return False
    _raw_decoder_error = None
    return True


def image_preview(
    source, destination, *, max_edge=MAX_PREVIEW_EDGE, quality=90, source_format=None
):
    """Decode bounded RAW/HEIF/raster sources into a browser-safe JPEG file."""
    from PIL import Image, ImageOps
    from pillow_heif import register_heif_opener

    source, destination = Path(source), Path(destination)
    if not source.is_file() or source.stat().st_size > MAX_PREVIEW_SOURCE_BYTES:
        raise ValueError("This image exceeds the 256 MB RAW and image source limit.")
    edge = min(MAX_PREVIEW_EDGE, max(64, int(max_edge)))
    quality = min(95, max(60, int(quality)))
    suffix = (source_format or source.suffix).lower()
    raw_image = suffix in RAW_SUFFIXES
    register_heif_opener()
    image = None
    try:
        if raw_image:
            if _raw_decoder_error:
                raise ValueError(_raw_decoder_error)
            _tiff_raw_preflight(source)
            import rawpy

            raw = rawpy.RawPy()
            try:
                # Read only the header before allocating/decompressing RAW pixels.
                raw.open_file(str(source))
                sizes = raw.sizes
                pixels = max(
                    int(sizes.raw_width) * int(sizes.raw_height),
                    int(sizes.width) * int(sizes.height),
                )
                if pixels <= 0 or pixels > MAX_PREVIEW_PIXELS:
                    raise ValueError("This RAW image exceeds the 120 megapixel preview limit.")
                if edge <= 1024:
                    try:
                        thumb = raw.extract_thumb()
                        if (
                            thumb.format == rawpy.ThumbFormat.JPEG
                            and len(thumb.data) <= 8 * 1024 * 1024
                        ):
                            image = Image.open(io.BytesIO(thumb.data))
                        elif thumb.format == rawpy.ThumbFormat.BITMAP:
                            if thumb.data.shape[0] * thumb.data.shape[1] <= MAX_PREVIEW_PIXELS:
                                image = Image.fromarray(thumb.data)
                    except (rawpy.LibRawNoThumbnailError, rawpy.LibRawUnsupportedThumbnailError):
                        pass
                if image is None:
                    raw.unpack()
                    rgb = raw.postprocess(
                        half_size=True,
                        use_camera_wb=True,
                        output_bps=8,
                        output_color=rawpy.ColorSpace.sRGB,
                    )
                    image = Image.fromarray(rgb)
            finally:
                raw.close()
        else:
            image = Image.open(source)
        if image.format not in (
            None,
            "JPEG",
            "MPO",
            "PNG",
            "GIF",
            "WEBP",
            "TIFF",
            "BMP",
            "DIB",
            "HEIF",
            "AVIF",
            "ICO",
            "ICNS",
            "PSD",
            "TGA",
            "DDS",
            "JPEG2000",
            "PPM",
            "QOI",
            "PCX",
            "SGI",
            "SUN",
            "XBM",
        ):
            raise ValueError("This image format has no safe in-app raster decoder.")
        if image.width * image.height > MAX_PREVIEW_PIXELS or image.width <= 0 or image.height <= 0:
            raise ValueError("This image exceeds the 120 megapixel preview limit.")
        original = (image.width, image.height)
        image = ImageOps.exif_transpose(image)
        image.thumbnail((edge, edge), Image.Resampling.LANCZOS)
        if image.mode in ("RGBA", "LA") or image.mode == "P" and "transparency" in image.info:
            rgba = image.convert("RGBA")
            background = Image.new("RGB", rgba.size, "white")
            background.paste(rgba, mask=rgba.getchannel("A"))
            image = background
        else:
            image = image.convert("RGB")
        image.save(destination, "JPEG", quality=quality, optimize=True)
        return {
            "width": image.width,
            "height": image.height,
            "originalWidth": original[0],
            "originalHeight": original[1],
            "raw": raw_image,
            "rendered": True,
        }
    except ValueError:
        raise
    except Exception:
        raise ValueError(
            "The image could not be decoded. Its RAW variant may be unsupported or the file may be incomplete."
        ) from None
    finally:
        if image is not None:
            image.close()


def convert_photos(store, backup, ids, destination, job):
    from PIL import Image, ImageOps
    from pillow_heif import register_heif_opener

    register_heif_opener()
    entries = store.entries(backup, ids)
    paths = []
    for index, entry in enumerate(entries):
        job.check()
        image = Image.open(io.BytesIO(store.bytes(backup, entry)))
        if image.width * image.height > 100_000_000:
            raise ValueError("This image exceeds the conversion size limit.")
        image = ImageOps.exif_transpose(image)
        out = io.BytesIO()
        image.convert("RGB").save(out, "JPEG", quality=95)
        name = Path(safe_component(Path(entry["relativePath"]).name)).stem + ".jpg"
        paths.append(publish_bytes(Path(destination) / name, out.getvalue()))
        job.progress((index + 1) / max(1, len(entries)) * 100, "Converting photos to JPEG")
    return {"output": str(Path(destination).resolve()), "count": len(paths)}


def create_ringtone(source, destination, job):
    import av

    source = Path(source).resolve()
    destination = Path(destination).resolve()
    if not source.is_file():
        raise ValueError("Choose an audio file first.")
    if destination.exists():
        raise ValueError("Choose a new ringtone filename to preserve the existing file.")
    temp = destination.with_name(destination.name + "." + job.id + ".partial")
    try:
        with av.open(str(source)) as input:
            if not input.streams.audio:
                raise ValueError("The selected file has no audio track.")
            with av.open(str(temp), "w", format="ipod") as output:
                stream = output.add_stream("aac", rate=44100)
                stream.layout = "stereo"
                stream.bit_rate = 192000
                resampler = av.AudioResampler(format="fltp", layout="stereo", rate=44100)
                samples = 0
                for frame in input.decode(audio=0):
                    job.check()
                    for converted in resampler.resample(frame):
                        if samples + converted.samples > 44100 * 30:
                            break
                        converted.pts = None
                        for packet in stream.encode(converted):
                            output.mux(packet)
                        samples += converted.samples
                    job.progress(
                        min(99, samples / (44100 * 30) * 100),
                        "Creating up to 30 seconds of AAC audio",
                    )
                    if samples >= 44100 * 30 - 8192:
                        break
                for packet in stream.encode(None):
                    output.mux(packet)
        job.check()
        os.rename(temp, destination)
        return {"output": str(destination), "seconds": round(samples / 44100, 2)}
    finally:
        temp.unlink(missing_ok=True)
