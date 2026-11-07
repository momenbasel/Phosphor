"""Read the documented plaintext field in Apple Notes' compressed protobuf.

Field map: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/master/proto/notestore.proto
No guessed printable strings, note-password decryption, or HTML execution.
"""

import zlib

MAX_NOTE_BYTES = 8 * 1024 * 1024


def _varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError("Truncated protobuf")
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, offset
    raise ValueError("Oversized protobuf value")


def _field(data, target):
    offset = 0
    while offset < len(data):
        tag, offset = _varint(data, offset)
        field = tag >> 3
        wire = tag & 7
        if field == 0:
            raise ValueError("Invalid protobuf field")
        if wire == 0:
            _, offset = _varint(data, offset)
        elif wire in (1, 5):
            offset += 8 if wire == 1 else 4
        elif wire == 2:
            size, offset = _varint(data, offset)
            end = offset + size
            if end > len(data):
                raise ValueError("Truncated protobuf field")
            if field == target:
                return data[offset:end]
            offset = end
        else:
            raise ValueError("Unsupported protobuf wire type")
        if offset > len(data):
            raise ValueError("Truncated protobuf")
    return None


def decode_note_text(blob):
    if not isinstance(blob, (bytes, bytearray, memoryview)) or not blob:
        return None
    data = bytes(blob)
    if len(data) > MAX_NOTE_BYTES:
        return None
    try:
        if data[:2] == b"\x1f\x8b":
            inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
            data = inflater.decompress(data, MAX_NOTE_BYTES + 1)
            if len(data) > MAX_NOTE_BYTES or not inflater.eof:
                return None
        document = _field(data, 2)
        note = _field(document, 3) if document is not None else None
        text = _field(note, 2) if note is not None else None
        return text.decode("utf-8") if text is not None else None
    except (ValueError, UnicodeDecodeError, zlib.error, TypeError):
        return None
