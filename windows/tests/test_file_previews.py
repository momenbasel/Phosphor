import base64
from pathlib import Path
import zipfile

import pytest
from PIL import Image

from file_browser import FileBrowser
from preview_cache import CHUNK, PreviewCache
from test_media_previews import synthetic_dng


def browser_root(tmp_path):
    browser = FileBrowser(None, tmp_path / "profile")
    root = tmp_path / "files"
    root.mkdir()
    token = browser.register_local(root)["root"]
    return browser, root, token


def test_pdf_larger_than_old_cap_streams_a_range_without_loading_whole_file(tmp_path, monkeypatch):
    browser, root, token = browser_root(tmp_path)
    pdf = root / "large.pdf"
    with pdf.open("wb") as output:
        output.write(b"%PDF-1.7\n")
        output.seek(12 * CHUNK)
        output.write(b"%%EOF")
    monkeypatch.setattr(Path, "read_bytes", lambda *_: pytest.fail("PDF should stream file ranges"))
    result = browser.preview(source="local", root=token, path="/large.pdf")
    assert result["kind"] == "pdf" and result["size"] > 8 * CHUNK
    assert browser.preview_info(result["token"])["mime"] == "application/pdf"
    chunk = browser.preview_chunk(result["token"], offset=12 * CHUNK, length=CHUNK)
    assert base64.b64decode(chunk["data"]) == b"%%EOF" and chunk["eof"]
    assert browser.token_udid(result["token"]) == ""
    browser.release(result["token"])
    with pytest.raises(ValueError, match="expired"):
        browser.preview_info(result["token"])


def test_large_text_reads_only_bounded_prefix(tmp_path, monkeypatch):
    browser, root, token = browser_root(tmp_path)
    with (root / "large.txt").open("wb") as output:
        for _ in range(10):
            output.write(b"a" * CHUNK)
    calls = []
    original = browser._read_preview

    def read(record, offset, length):
        calls.append((offset, length))
        return original(record, offset, length)

    monkeypatch.setattr(browser, "_read_preview", read)
    result = browser.preview(source="local", root=token, path="/large.txt")
    assert result["kind"] == "text" and result["truncated"]
    assert len(result["text"]) == 700000
    assert calls == [(0, CHUNK), (CHUNK, CHUNK)]


def test_file_browser_raw_decodes_and_reuses_disk_rendition(tmp_path, monkeypatch):
    browser, root, token = browser_root(tmp_path)
    source = root / "photo.dng"
    synthetic_dng(source)
    before = source.read_bytes()
    first = browser.preview(source="local", root=token, path="/photo.dng")
    assert first["kind"] == "image" and first["raw"]
    output = base64.b64decode(browser.preview_chunk(first["token"])["data"])
    assert output.startswith(b"\xff\xd8")
    monkeypatch.setattr(
        "file_browser.image_preview",
        lambda *_a, **_k: pytest.fail("Cached RAW must not decode again"),
    )
    second = browser.preview(source="local", root=token, path="/photo.dng")
    assert base64.b64decode(browser.preview_chunk(second["token"])["data"]) == output
    assert source.read_bytes() == before


def test_local_token_is_revoked_when_original_changes(tmp_path):
    browser, root, token = browser_root(tmp_path)
    (root / "video.mp4").write_bytes(b"original")
    result = browser.preview(source="local", root=token, path="/video.mp4")
    (root / "video.mp4").write_bytes(b"changed content")
    with pytest.raises(ValueError, match="changed"):
        browser.preview_chunk(result["token"])


def test_backup_lock_revokes_cached_image_tokens_and_deletes_rendition(
    fixture_backup, tmp_path, monkeypatch
):
    store, backup, _ = fixture_backup
    browser = FileBrowser(store, tmp_path / "profile")
    result = browser.preview(
        source="backup", backup=backup, path="/CameraRollDomain/Media/DCIM/100APPLE/IMG_0001.PNG"
    )
    cached = browser.tokens[result["token"]]["cachedPath"]
    assert cached.exists()

    def locked(*_):
        raise ValueError("Unlock this backup")

    monkeypatch.setattr(store, "connection", locked)
    with pytest.raises(ValueError, match="Unlock"):
        browser.preview_chunk(result["token"])
    browser.invalidate(backup)
    assert not cached.exists() and result["token"] not in browser.tokens


def test_large_word_document_preview_ignores_embedded_assets_and_macros(tmp_path):
    browser, root, token = browser_root(tmp_path)
    source = root / "document.docm"
    with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr(
            "word/document.xml",
            '<w:document xmlns:w="urn:word"><w:p><w:r><w:t>Hello &lt;script&gt;alert(1)&lt;/script&gt;</w:t></w:r></w:p></w:document>',
        )
        archive.writestr("word/media/image.bin", b"0" * (9 * CHUNK))
        archive.writestr("word/vbaProject.bin", b"not executed")
    result = browser.preview(source="local", root=token, path="/document.docm")
    assert result["kind"] == "document" and "<script>alert(1)</script>" in result["text"]
    assert "macros" in result["notice"] and result["sourceSize"] > 8 * CHUNK


def test_office_external_entities_are_rejected_without_network_or_execution(tmp_path):
    browser, root, token = browser_root(tmp_path)
    with zipfile.ZipFile(root / "unsafe.docx", "w") as archive:
        archive.writestr(
            "word/document.xml",
            '<!DOCTYPE doc [<!ENTITY external SYSTEM "file:///C:/private.txt">]><doc><p>&external;</p></doc>',
        )
    with pytest.raises(ValueError, match="safely read"):
        browser.preview(source="local", root=token, path="/unsafe.docx")


def test_workbook_and_presentation_return_safe_readable_structures(tmp_path):
    browser, root, token = browser_root(tmp_path)
    with zipfile.ZipFile(root / "book.xlsx", "w") as archive:
        archive.writestr(
            "xl/workbook.xml",
            '<workbook><sheets><sheet sheetId="1" name="Budget"/></sheets></workbook>',
        )
        archive.writestr("xl/sharedStrings.xml", "<sst><si><t>Hello</t></si></sst>")
        archive.writestr(
            "xl/worksheets/sheet1.xml",
            '<worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><f>1+2</f><v>3</v></c></row></sheetData></worksheet>',
        )
    book = browser.preview(source="local", root=token, path="/book.xlsx")
    assert "Budget" in book["text"] and "A1: Hello" in book["text"] and "B1: 3" in book["text"]
    with zipfile.ZipFile(root / "slides.pptx", "w") as archive:
        archive.writestr("ppt/slides/slide1.xml", "<slide><p><r><t>Title</t></r></p></slide>")
    slides = browser.preview(source="local", root=token, path="/slides.pptx")
    assert "Slide 1" in slides["text"] and "Title" in slides["text"]


def test_rtf_utf16_surrogate_text_and_script_sources_are_passive_text(tmp_path):
    browser, root, token = browser_root(tmp_path)
    (root / "text.rtf").write_bytes(
        b"{\\rtf1 Test\\par \\u9731? \\u-10179?\\u-8701? {\\object hidden payload}}"
    )
    text = browser.preview(source="local", root=token, path="/text.rtf")["text"]
    assert "☃" in text and "😃" in text and "hidden" not in text
    (root / "unsafe.svg").write_text('<svg onload="alert(1)"></svg>')
    svg = browser.preview(source="local", root=token, path="/unsafe.svg")
    assert svg["kind"] == "text" and "onload" in svg["text"] and "token" not in svg


@pytest.mark.parametrize(
    "suffix,first,second",
    [
        (".pptx", "ppt/slides/slide1.xml", "ppt/slides/slide2.xml"),
        (".epub", "chapter1.xhtml", "chapter2.xhtml"),
    ],
)
def test_compressed_documents_bound_aggregate_text_before_parsing_more_parts(
    tmp_path, monkeypatch, suffix, first, second
):
    import document_preview

    source = tmp_path / ("large" + suffix)
    with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(first, "<document><p><t>" + "Readable " * 250000 + "</t></p></document>")
        # Once the preview budget is full, the reader must not parse further
        # content; even an invalid later part cannot expand the preview work.
        archive.writestr(second, "<!DOCTYPE doc><doc><p>not reached</p></doc>")
    assert source.stat().st_size < 10000
    calls = []
    original = document_preview._xml

    def read(archive, name):
        calls.append(name)
        return original(archive, name)

    monkeypatch.setattr(document_preview, "_xml", read)
    result = document_preview.office_preview(source, suffix)
    assert calls == [first]
    assert result["truncated"] is True
    assert len(result["text"]) == document_preview.MAX_TEXT_CHARS
    assert "Readable" in result["text"]
