from __future__ import annotations

from pathlib import Path
import sqlite3
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def make_corrupt_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA page_size=1024")
    connection.execute("PRAGMA journal_mode=DELETE")
    connection.execute("CREATE TABLE records(id INTEGER PRIMARY KEY, value BLOB)")
    for index in range(1, 501):
        connection.execute("INSERT INTO records(value) VALUES (?)", (bytes([index % 251]) * 700,))
    connection.commit()
    connection.close()

    page_size = 1024
    page_count = path.stat().st_size // page_size
    target_page = max(5, page_count // 2)
    with path.open("r+b") as handle:
        handle.seek((target_page - 1) * page_size)
        handle.write(b"\0" * page_size)


def test_sqlite_reader_throws_on_terminal_step_errors(root: Path) -> None:
    source = root / "Sources/Phosphor/Utilities/SQLiteReader.swift"
    probe = r'''
import Foundation

@main
struct Probe {
    static func main() throws {
        let reader = try SQLiteReader(path: CommandLine.arguments[1])
        do {
            let rows = try reader.query("SELECT id, length(value) FROM records ORDER BY id")
            print("ROWS|\(rows.count)")
        } catch {
            print("ERROR|\(error.localizedDescription)")
        }
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        database = temp / "corrupt.sqlite"
        make_corrupt_database(database)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "sqlite-step-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(source), str(probe_path), "-lsqlite3", "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(database)], capture_output=True, text=True, timeout=15)

    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith("ERROR|"), (
        "SQLiteReader must not silently return partial rows when sqlite3_step fails; " + result.stdout
    )
    assert "malformed" in result.stdout.lower(), result.stdout


def test_sqlite_reader_copies_bound_text_and_checks_bind_failures(root: Path) -> None:
    source = read(root, "Sources/Phosphor/Utilities/SQLiteReader.swift")
    assert "SQLITE_TRANSIENT" in source, "bound strings must be copied for the statement lifetime"
    assert "sqlite3_bind_text" in source and "bindFailed" in source, "bind return codes must be checked and typed"
    assert "while true" in source and "SQLITE_DONE" in source, "query must distinguish DONE from terminal step errors"
