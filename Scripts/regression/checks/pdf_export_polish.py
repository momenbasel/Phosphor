from __future__ import annotations

from pathlib import Path


def _read(root: Path, relative_path: str) -> str:
    return (root / relative_path).read_text()


def test_pdf_links_are_clickable_and_timestamps_follow_conversation_gaps(root: Path) -> None:
    exporter = _read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    writer = _read(root, "Sources/Phosphor/Utilities/PDFTranscriptWriter.swift")

    assert "timestamp: msg.date" in exporter, "PDF entries must carry message Date values for calendar/gap separators"
    assert "context.setURL" in writer, "PDF link cards must publish a real PDF URI annotation"
    assert "calendar.isDate" in writer, "PDF timestamp separators must account for calendar-day changes"
    assert "timeIntervalSince" in writer, "PDF timestamp separators must account for meaningful message gaps"
