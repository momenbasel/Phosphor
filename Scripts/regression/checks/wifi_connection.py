from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def test_network_device_grace_cache_absorbs_one_missed_poll(root: Path) -> None:
    source = root / "Sources/Phosphor/Utilities/NetworkDeviceGraceCache.swift"
    probe = r'''
import Foundation

@main
struct Probe {
    static func main() {
        var cache = NetworkDeviceGraceCache<String>(maxMissedScans: 1)

        precondition(cache.merge(current: [(id: "wifi-a", value: "first")]) == ["first"])
        precondition(cache.merge(current: []) == ["first"])
        precondition(cache.merge(current: [(id: "wifi-a", value: "refreshed")]) == ["refreshed"])
        precondition(cache.merge(current: []) == ["refreshed"])
        precondition(cache.merge(current: []).isEmpty)

        precondition(cache.merge(current: [(id: "wifi-a", value: "wireless")]) == ["wireless"])
        cache.remove(ids: ["wifi-a"])
        precondition(cache.merge(current: []).isEmpty)
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "network-grace-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(source), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr

    manager = (root / "Sources/Phosphor/Services/DeviceManager.swift").read_text()
    assert "NetworkDeviceGraceCache<DeviceInfo>" in manager, "the grace cache must retain rendered device snapshots, not entries that still require a failing metadata fetch"
    assert "stableNetworkDevices" in manager, "DeviceManager must merge retained DeviceInfo snapshots into the published device list"
    assert 'discoveredEntries.filter { $0.connectionType == "USB" }.map(\.udid)' in manager, "USB discovery must evict a stale Wi-Fi snapshot even when USB metadata fetching fails"


def test_network_device_grace_cache_preserves_discovery_order(root: Path) -> None:
    source = root / "Sources/Phosphor/Utilities/NetworkDeviceGraceCache.swift"
    probe = r'''
import Foundation

@main
struct Probe {
    static func main() {
        var cache = NetworkDeviceGraceCache<String>(maxMissedScans: 1)

        let first = cache.merge(current: [(id: "wifi-b", value: "B"), (id: "wifi-a", value: "A")])
        precondition(first == ["B", "A"])
        precondition(cache.merge(current: []) == ["B", "A"])
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "network-grace-order-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(source), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
