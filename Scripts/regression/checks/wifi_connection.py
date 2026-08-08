from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def test_pymobiledevice_usbmux_discovery_is_timeout_bounded(root: Path) -> None:
    source = (root / "Sources/Phosphor/Utilities/PyMobileDevice.swift").read_text()
    discovery = source.split("static func listDevicesWithType()", 1)[1].split(
        "static func listNetworkDeviceEntries()", 1
    )[0]

    assert 'runAsync(["usbmux", "list", "--usb"], timeout: 5)' in discovery, (
        "a stalled USB compatibility probe must not freeze DeviceManager scanning for "
        "PyMobileDevice.runAsync's five-minute default"
    )
    assert 'runAsync(["usbmux", "list", "--network"], timeout: 5)' in discovery, (
        "network compatibility discovery must remain timeout bounded"
    )
    assert 'runAsync(["usbmux", "list"], timeout: 5)' in discovery, (
        "the default usbmux fallback must not turn an empty compatibility scan into a "
        "five-minute polling stall"
    )


def test_compatibility_cache_distinguishes_probe_failure_from_empty_scan(root: Path) -> None:
    source = root / "Sources/Phosphor/Utilities/AuthoritativeSnapshotCache.swift"
    probe = r'''
import Foundation

@main
struct Probe {
    static func main() {
        var cache = AuthoritativeSnapshotCache<String>(maxStaleAge: 30, maxNonAuthoritativeMerges: 2)
        let start = Date(timeIntervalSince1970: 1_000)

        precondition(cache.merge(current: [(id: "wifi-a", value: "A1")], authoritative: true, now: start) == ["A1"])
        precondition(cache.merge(current: [], authoritative: false, now: start.addingTimeInterval(10)) == ["A1"])
        precondition(cache.merge(current: [(id: "wifi-a", value: "A2"), (id: "wifi-b", value: "B")], authoritative: false, now: start.addingTimeInterval(20)) == ["A2", "B"])
        precondition(cache.merge(current: [], authoritative: false, now: start.addingTimeInterval(21)).isEmpty)
        precondition(cache.merge(current: [(id: "wifi-b", value: "B2")], authoritative: true, now: start.addingTimeInterval(40)) == ["B2"])
        precondition(cache.merge(current: [], authoritative: true, now: start.addingTimeInterval(41)).isEmpty)

        var ageBounded = AuthoritativeSnapshotCache<String>(maxStaleAge: 30, maxNonAuthoritativeMerges: 10)
        precondition(ageBounded.merge(current: [(id: "wifi-a", value: "A")], authoritative: true, now: start) == ["A"])
        precondition(ageBounded.merge(current: [], authoritative: false, now: start.addingTimeInterval(31)).isEmpty)
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "authoritative-snapshot-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(source), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr


def test_partial_discovery_uses_bounded_retry_backoff(root: Path) -> None:
    source = root / "Sources/Phosphor/Utilities/DiscoveryRetryBackoff.swift"
    probe = r'''
import Foundation

@main
struct Probe {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000)
        var retry = DiscoveryRetryBackoff(initialDelay: 5, maximumDelay: 30)
        precondition(retry.isDue(at: start))
        retry.recordFailure(at: start)
        precondition(!retry.isDue(at: start.addingTimeInterval(4)))
        precondition(retry.isDue(at: start.addingTimeInterval(5)))
        retry.recordFailure(at: start.addingTimeInterval(5))
        precondition(!retry.isDue(at: start.addingTimeInterval(14)))
        precondition(retry.isDue(at: start.addingTimeInterval(15)))
        retry.recordSuccess(at: start.addingTimeInterval(15), regularInterval: 30)
        precondition(!retry.isDue(at: start.addingTimeInterval(44)))
        precondition(retry.isDue(at: start.addingTimeInterval(45)))
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "discovery-retry-probe"
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
    assert "compatibilityDiscoveryRetry.isDue(at: scanStartedAt)" in manager
    assert "compatibilityDiscoveryRetry.recordFailure(at: discoveryCompletedAt)" in manager


def test_non_authoritative_fallback_cannot_fabricate_usb_transport(root: Path) -> None:
    pymobiledevice = (root / "Sources/Phosphor/Utilities/PyMobileDevice.swift").read_text()
    manager = (root / "Sources/Phosphor/Services/DeviceManager.swift").read_text()

    assert 'defaultConnectionType: "Unknown"' in pymobiledevice
    assert '$0.connectionType == "USB" || $0.connectionType == "Network"' in manager
    assert 'discoveredEntries.filter { $0.connectionType == "USB" }' in manager
    assert "retainedCompatibilityDeviceIDs.contains(entry.udid)" in manager
    assert "if !forceRefresh," in manager
    assert "(!forceRefresh || compatibilityProbeFailed)" not in manager
    assert "current: []," in manager and "now: discoveryCompletedAt" in manager
    skipped_probe = manager.split("} else {\n            // Skipping an expensive probe", 1)[1].split("let visibleUDIDs", 1)[0]
    assert "compatibilityOnlyDeviceCache.values" in skipped_probe
    assert "compatibilityOnlyDeviceCache.merge" not in skipped_probe, (
        "routine lightweight polls must not consume the stale-entry failure budget"
    )
    assert "compatibilityDiscoveryRetry.consecutiveFailures == 0" in manager


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
