import threading

import pytest

from preview_cache import PreviewCache, CHUNK


def test_cache_reuses_rendition_expires_and_stores_only_opaque_paths(tmp_path):
    clock = [1000.0]
    cache = PreviewCache(tmp_path, ttl=60, max_bytes=20, clock=lambda: clock[0])
    calls = []

    def writer(path):
        calls.append(True)
        path.write_bytes(b"preview")

    path = cache.put("private-account@example.test", "/private/image.dng", writer)
    assert path.name.endswith(".jpg") and "/private/" not in path.name
    assert cache.get("private-account@example.test", "/private/image.dng") == path
    assert cache.put("private-account@example.test", "/private/image.dng", writer) == path
    assert len(calls) == 1
    clock[0] += 61
    cache.prune()
    assert not path.exists()
    assert cache.get("private-account@example.test", "/private/image.dng") is None


def test_cache_bounds_total_disk_size_and_invalidates_only_scope(tmp_path):
    clock = [1000.0]
    cache = PreviewCache(tmp_path, max_bytes=12, clock=lambda: clock[0])
    first = cache.put("one", "a", lambda path: path.write_bytes(b"123456"))
    clock[0] += 1
    second = cache.put("two", "b", lambda path: path.write_bytes(b"abcdef"))
    clock[0] += 1
    third = cache.put("two", "c", lambda path: path.write_bytes(b"abcdef"))
    assert not first.exists() and second.exists() and third.exists()
    cache.invalidate("two")
    assert not second.exists() and not third.exists()


def test_cache_materializes_in_bounded_chunks_and_rejects_short_reads(tmp_path):
    cache = PreviewCache(tmp_path)
    requested = []

    def read(offset, length):
        requested.append((offset, length))
        return b"x" * length

    path = cache.materialize("source", "a", CHUNK + 3, read)
    assert requested == [(0, CHUNK), (CHUNK, 3)]
    assert cache.read(path, CHUNK, 10) == b"xxx"
    with pytest.raises(ValueError, match="incomplete"):
        cache.materialize("source", "bad", 5, lambda *_: b"ab")
    assert not list(cache.root.glob(".stage-*"))
    with pytest.raises(ValueError, match="source size"):
        cache.materialize("source", "large", 20, read, max_item_bytes=10)


def test_cache_never_removes_or_reads_unregistered_user_paths(tmp_path):
    cache = PreviewCache(tmp_path / "profile")
    original = tmp_path / "original.txt"
    original.write_text("user original")
    with pytest.raises(ValueError, match="leaves the cache"):
        cache.remove(original)
    with pytest.raises(ValueError, match="leaves the cache"):
        cache.read(original)
    cache.invalidate()
    assert original.read_text() == "user original"


def test_cache_singleton_and_atomic_parallel_generation(tmp_path):
    cache = PreviewCache(tmp_path)
    assert PreviewCache(tmp_path) is cache
    outputs, calls = [], []

    def writer(path):
        calls.append(True)
        path.write_bytes(b"consistent")

    threads = [
        threading.Thread(target=lambda: outputs.append(cache.put("scope", "same", writer)))
        for _ in range(4)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert len(calls) == 1 and len(set(outputs)) == 1
    assert outputs[0].read_bytes() == b"consistent"


def test_cache_checks_budget_and_does_not_publish_failed_writer(tmp_path):
    cache = PreviewCache(tmp_path, max_bytes=8)
    with pytest.raises(ValueError, match="disk cache limit"):
        cache.put("scope", "large", lambda path: path.write_bytes(b"x" * 10))
    assert not list(cache.root.glob("*.jpg"))
    assert not list(cache.root.glob(".stage-*"))
