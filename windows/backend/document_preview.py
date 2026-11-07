"""Read-only structured previews. No Office process, macros, HTML, or links run."""

from __future__ import annotations

import codecs
import csv
import io
from pathlib import Path
import re
import zipfile

from defusedxml import ElementTree as XML
from defusedxml.common import DefusedXmlException

MAX_TEXT_BYTES = 2 * 1024 * 1024
MAX_TEXT_CHARS = 700000
MAX_XML_BYTES = 32 * 1024 * 1024
OFFICE_SUFFIXES = frozenset(
    {
        ".docx",
        ".dotx",
        ".docm",
        ".dotm",
        ".xlsx",
        ".xltx",
        ".xlsm",
        ".xltm",
        ".pptx",
        ".pptm",
        ".ppsx",
        ".odp",
        ".odt",
        ".ods",
        ".epub",
    }
)


def text_preview(data: bytes, *, total_size: int | None = None) -> dict:
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        encoding = "utf-16"
    else:
        encoding = "utf-8-sig"
    try:
        text = codecs.getincrementaldecoder(encoding)(errors="strict").decode(data, final=False)
    except UnicodeError:
        # Legacy documents and logs often use Windows-1252; plain binary data
        # is still rejected by its control-character ratio below.
        text = data.decode("cp1252", errors="replace")
        encoding = "Windows-1252"
    if "\x00" in text or sum(ord(c) < 32 and c not in "\r\n\t" for c in text[:8000]) > 20:
        return {
            "kind": "binary",
            "text": _hex(data[:65536]),
            "truncated": (total_size or len(data)) > 65536,
            "previewLabel": "Binary data · first 64 KB",
            "encoding": None,
        }
    return {
        "kind": "text",
        "text": text[:MAX_TEXT_CHARS],
        "truncated": len(text) > MAX_TEXT_CHARS or (total_size or len(data)) > len(data),
        "encoding": encoding,
        "previewLabel": "Text preview",
    }


def _hex(data: bytes) -> str:
    return "\n".join(
        f"{offset:08x}  "
        + " ".join(f"{b:02x}" for b in data[offset : offset + 16]).ljust(47)
        + "  "
        + "".join(chr(b) if 32 <= b < 127 else "." for b in data[offset : offset + 16])
        for offset in range(0, len(data), 16)
    )


def _member(archive: zipfile.ZipFile, name: str):
    try:
        info = archive.getinfo(name)
    except KeyError:
        raise ValueError("This document does not contain a readable preview part.") from None
    if info.file_size > MAX_XML_BYTES or info.flag_bits & 1:
        raise ValueError(
            "This document’s text part is too large or encrypted for a safe structured preview."
        )
    return archive.open(info)


def _xml(archive: zipfile.ZipFile, name: str):
    try:
        with _member(archive, name) as stream:
            return XML.parse(
                stream, forbid_dtd=True, forbid_entities=True, forbid_external=True
            ).getroot()
    except (DefusedXmlException, XML.ParseError):
        raise ValueError(
            "This document’s content could not be safely read. Its XML is damaged or contains prohibited declarations."
        ) from None


def _tag(element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def _bounded_join(parts, separator="") -> str:
    """Bound text while collecting, including one character as a clipping marker."""
    chunks = []
    length = 0
    limit = MAX_TEXT_CHARS + 1
    for text in parts:
        if not text:
            continue
        if chunks and separator:
            prefix = separator[: limit - length]
            chunks.append(prefix)
            length += len(prefix)
        if length >= limit:
            break
        part = text[: limit - length]
        chunks.append(part)
        length += len(part)
        if length >= limit:
            break
    return "".join(chunks)


def _paragraphs(root, tags=("p",)) -> str:
    def paragraphs():
        for element in root.iter():
            if _tag(element) in tags:
                yield _bounded_join(
                    node.text or ""
                    for node in element.iter()
                    if _tag(node) in ("t", "span", "a", "p", "h") or len(node) == 0
                )

    return _bounded_join(paragraphs(), "\n\n")


def office_preview(path: Path, suffix: str) -> dict:
    with zipfile.ZipFile(path) as archive:
        if len(archive.infolist()) > 20000:
            raise ValueError("This document contains too many parts for a safe preview.")
        note = (
            "Read-only content preview. Page layout, embedded objects and macros are not rendered."
        )
        if suffix in (".docx", ".dotx", ".docm", ".dotm"):
            root = _xml(archive, "word/document.xml")
            text = _paragraphs(root)
            title = "Word document · content preview"
        elif suffix in (".xlsx", ".xltx", ".xlsm", ".xltm"):
            strings = []
            if "xl/sharedStrings.xml" in archive.namelist():
                root = _xml(archive, "xl/sharedStrings.xml")
                for item in root:
                    strings.append(
                        _bounded_join(node.text or "" for node in item.iter() if _tag(node) == "t")
                    )
                    if len(strings) >= 100000:
                        break
            names = {}
            if "xl/workbook.xml" in archive.namelist():
                root = _xml(archive, "xl/workbook.xml")
                for item in root.iter():
                    if _tag(item) == "sheet":
                        names[item.attrib.get("sheetId", "")] = item.attrib.get("name", "Sheet")
            sheets = sorted(
                (
                    name
                    for name in archive.namelist()
                    if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", name)
                ),
                key=lambda value: int(re.search(r"\d+", value)[0]),
            )[:10]
            if not sheets:
                raise ValueError("No worksheet content is available in this workbook.")

            def sections():
                for sheet in sheets:
                    root = _xml(archive, sheet)

                    def lines():
                        for index, row in enumerate(
                            element for element in root.iter() if _tag(element) == "row"
                        ):
                            if index >= 1000:
                                break

                            def cells():
                                for cell in list(row)[:50]:
                                    value = _bounded_join(
                                        node.text or ""
                                        for node in cell.iter()
                                        if _tag(node) in ("v", "t")
                                    )
                                    if cell.attrib.get("t") == "s":
                                        index = (
                                            int(value)
                                            if value.isdigit() and len(value) < 10
                                            else -1
                                        )
                                        value = (
                                            strings[index]
                                            if 0 <= index < len(strings)
                                            else "[shared text unavailable]"
                                        )
                                    label = cell.attrib.get("r", "")[:100]
                                    yield (label + ": " if label else "") + value

                            yield _bounded_join(cells(), "  |  ")

                    number = re.search(r"\d+", sheet)[0]
                    yield names.get(number, "Sheet " + number)[
                        : MAX_TEXT_CHARS + 1
                    ] + "\n" + _bounded_join(lines(), "\n")

            text = _bounded_join(sections(), "\n\n")
            note = "Read-only cell values: up to 10 sheets, 1,000 rows and 50 columns per sheet. Formulas use stored results; macros and external links do not run."
            title = "Workbook · cell preview"
        elif suffix in (".pptx", ".pptm", ".ppsx"):
            slides = sorted(
                (
                    name
                    for name in archive.namelist()
                    if re.fullmatch(r"ppt/slides/slide\d+\.xml", name)
                ),
                key=lambda value: int(re.search(r"\d+", value)[0]),
            )[:200]
            if not slides:
                raise ValueError("No slide text is available in this presentation.")
            text = _bounded_join(
                (
                    "Slide " + re.search(r"\d+", name)[0] + "\n" + _paragraphs(_xml(archive, name))
                    for name in slides
                ),
                "\n\n",
            )
            title = "Presentation · slide text"
        elif suffix in (".odt", ".ods", ".odp"):
            root = _xml(archive, "content.xml")
            text = _paragraphs(root, ("p", "h"))
            title = "OpenDocument · content preview"
        elif suffix == ".epub":
            parts = [
                name
                for name in archive.namelist()
                if name.lower().endswith((".xhtml", ".html", ".htm"))
            ][:100]
            text = _bounded_join(
                (_paragraphs(_xml(archive, name), ("p", "h1", "h2", "h3", "h4")) for name in parts),
                "\n\n",
            )
            title = "EPUB · text preview"
        else:
            raise ValueError("This document format is not supported by the structured reader.")
    return {
        "kind": "document",
        "text": text[:MAX_TEXT_CHARS] or "No readable text was included in this document.",
        "truncated": len(text) > MAX_TEXT_CHARS,
        "previewLabel": title,
        "notice": note,
    }


def rtf_preview(data: bytes, *, total_size: int | None = None) -> dict:
    text = data.decode("latin1")
    if not text.lstrip().startswith("{\\rtf"):
        return text_preview(data, total_size=total_size)
    output = []
    stack = []
    skip = False
    uc = 1
    fallback = 0
    index = 0
    control = re.compile(r"([a-zA-Z]{1,32})(-?\d{1,10})? ?")
    destinations = {
        "fonttbl",
        "colortbl",
        "stylesheet",
        "info",
        "pict",
        "object",
        "datastore",
        "themedata",
        "xmlnstbl",
        "filetbl",
    }
    while index < len(text) and len(output) < MAX_TEXT_CHARS:
        character = text[index]
        index += 1
        if character == "{":
            if len(stack) >= 256:
                raise ValueError("This RTF document is nested too deeply to preview safely.")
            stack.append((skip, uc))
            continue
        if character == "}":
            if stack:
                skip, uc = stack.pop()
            continue
        if character != "\\":
            if fallback:
                fallback -= 1
            elif not skip and character not in "\r\n":
                output.append(character)
            continue
        if index >= len(text):
            break
        escaped = text[index]
        if escaped in "{}\\":
            index += 1
            if fallback:
                fallback -= 1
            elif not skip:
                output.append(escaped)
            continue
        if escaped == "'" and index + 2 < len(text):
            value = text[index + 1 : index + 3]
            index += 3
            if fallback:
                fallback -= 1
            elif not skip:
                try:
                    output.append(bytes.fromhex(value).decode("cp1252"))
                except (ValueError, UnicodeError):
                    output.append("�")
            continue
        if escaped == "*":
            skip = True
            index += 1
            continue
        match = control.match(text, index)
        if not match:
            index += 1
            continue
        word, argument = match.groups()
        index = match.end()
        number = int(argument or 0)
        if word in destinations:
            skip = True
        elif word == "bin":
            index += max(0, number)
        elif word == "uc":
            uc = max(0, min(16, number))
        elif word == "u" and not skip:
            output.append(chr(number % 65536))
            fallback = uc
        elif word in ("par", "line") and not skip:
            output.append("\n")
        elif word == "tab" and not skip:
            output.append("\t")
    cleaned = "".join(output).encode("utf-16", "surrogatepass").decode("utf-16", "replace")
    return {
        "kind": "document",
        "text": cleaned,
        "truncated": index < len(text) or (total_size or len(data)) > len(data),
        "previewLabel": "RTF · text preview",
        "notice": "Read-only text preview; embedded objects are not executed.",
    }
