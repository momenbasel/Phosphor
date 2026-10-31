from pathlib import Path
import pytest
from console_store import ConsoleStore


def test_console_bounded_and_clear_keeps_saved(tmp_path):
    store = ConsoleStore(tmp_path)
    for _ in range(600):
        store.append("🙂" * 20000)
    assert store.line_bytes <= 8 * 1024 * 1024
    assert len(store.read()) < 600
    row = store.save()
    content = Path(row["path"]).read_text("utf-8")
    store.clear()
    assert not store.read() and store.line_bytes == 0
    assert (
        ConsoleStore(tmp_path).open(row["id"])["text"]
        == content[: len(ConsoleStore(tmp_path).open(row["id"])["text"])]
    )
    assert Path(row["path"]).is_file()


def test_save_no_overwrite_missing_and_invalid(tmp_path):
    store = ConsoleStore(tmp_path)
    with pytest.raises(ValueError):
        store.save()
    store.append("first")
    target = tmp_path / "console.txt"
    target.write_text("preserved")
    row = store.save(target)
    assert Path(row["path"]) != target and target.read_text() == "preserved"
    with pytest.raises(ValueError):
        store.save(tmp_path / "console.exe")
    Path(row["path"]).unlink()
    assert store.list()[0]["missing"]
    with pytest.raises(ValueError):
        store.open(row["id"])
    with pytest.raises(ValueError):
        store.open("unknown")
