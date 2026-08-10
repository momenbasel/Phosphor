"""A search term must be matched literally, not as a LIKE pattern.

Every search predicate in the app is parameterised, so there is no injection
here. But the bound value is still a LIKE *pattern*, and `%`, `_` and the escape
character keep their wildcard meaning inside it. Wrapping the raw term as
"%term%" meant a two-character query of `%%` became `%%%%`, which matches every
non-NULL row of every column searched - the unified search happily returned 250
arbitrary rows per source. `50%` matched "500 dollars" and `a_b` matched "axb".
"""
from __future__ import annotations

import sqlite3
from pathlib import Path

SEARCH_FILES = [
    "Sources/Phosphor/Services/CallLogExtractor.swift",
    "Sources/Phosphor/Services/ContactsExtractor.swift",
    "Sources/Phosphor/Services/NotesExtractor.swift",
    "Sources/Phosphor/Services/SafariExtractor.swift",
    "Sources/Phosphor/Services/MessageExporter.swift",
    "Sources/Phosphor/Services/WhatsAppExporter.swift",
]


def test_search_terms_are_escaped_and_every_predicate_declares_escape(root: Path) -> None:
    reader = (root / "Sources/Phosphor/Utilities/SQLiteReader.swift").read_text()
    assert "static func containsPattern" in reader, (
        "a single shared helper must build LIKE patterns so escaping cannot be "
        "forgotten at one of the call sites"
    )

    for rel in SEARCH_FILES:
        source = (root / rel).read_text()
        assert '"%\\(query)%"' not in source and '"%\\(normalized)%"' not in source, (
            f"{rel} still interpolates a raw search term into a LIKE pattern"
        )
        # Any parameterised LIKE in these files is a user-supplied search term
        # and must declare the escape character, or the escaping is inert.
        for line in source.splitlines():
            if "LIKE ?" in line:
                assert "ESCAPE" in line, f"{rel}: LIKE ? without ESCAPE: {line.strip()}"


def test_wildcard_query_does_not_match_every_row(root: Path) -> None:
    """Runs the real predicate shape against real SQLite."""
    reader = (root / "Sources/Phosphor/Utilities/SQLiteReader.swift").read_text()
    assert 'character == "\\\\" || character == "%" || character == "_"' in reader, (
        "the helper must escape backslash, percent and underscore"
    )

    def contains_pattern(term: str) -> str:
        out = ""
        for character in term:
            if character in "\\%_":
                out += "\\"
            out += character
        return f"%{out}%"

    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE t (v TEXT)")
    db.executemany(
        "INSERT INTO t VALUES (?)",
        [("hello",), ("world",), ("50% off",), ("a_b",), ("plain",)],
    )

    def matches(term: str) -> int:
        return db.execute(
            "SELECT count(*) FROM t WHERE v LIKE ? ESCAPE '\\'", (contains_pattern(term),)
        ).fetchone()[0]

    assert matches("%%") == 0, "a wildcard-only query must not match every row"
    assert matches("50%") == 1, "a literal percent must still match the row containing it"
    assert matches("a_b") == 1, "a literal underscore must still match"
    assert matches("hello") == 1, "ordinary terms must be unaffected"
