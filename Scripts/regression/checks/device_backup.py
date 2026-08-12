from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def assert_not_contains(text: str, needle: str, message: str) -> None:
    assert needle not in text, message


def test_pymobiledevice_queries_usb_and_network_before_fallback(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, 'runAsync(["usbmux", "list", "--usb"]', "device discovery must explicitly query USB devices")
    assert_contains(src, 'runAsync(["usbmux", "list", "--network"]', "device discovery must explicitly query network devices")
    assert_contains(src, 'runAsync(["usbmux", "list"], timeout: 5)', "device discovery should retain a timeout-bounded default usbmux fallback")
    assert_contains(src, 'entry["ConnectionType"] as? String', "usbmux JSON parser should inspect top-level ConnectionType")
    assert_contains(src, '(entry["Properties"] as? [String: Any])?["ConnectionType"] as? String', "usbmux JSON parser should inspect nested Properties.ConnectionType")


def test_bonjour_finder_visible_devices_are_discovery_hints(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, "struct BonjourDevice", "Bonjour-discovered devices should use a separate hint model")
    assert_contains(src, '"/usr/bin/dns-sd"', "Bonjour fallback should use macOS dns-sd directly")
    assert_contains(src, '"_apple-mobdev2._tcp"', "Bonjour fallback should browse Apple's MobileDevice service")
    assert_contains(src, "parseBonjourBrowseOutput", "Bonjour browse output should be parsed explicitly")
    assert_contains(src, "parseBonjourHost", "Bonjour resolve output should preserve the advertised host")
    assert_contains(src, "not the device UDID", "Bonjour identifiers must not be treated as backup-capable UDIDs")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "nearbyWirelessDevices", "DeviceManager should publish Finder-visible wireless hints")
    assert_contains(manager, "cachedBonjourDevices", "Bonjour discovery should be cached to avoid polling dns-sd constantly")
    assert_contains(manager, "connectedDevices = []", "Bonjour-only devices should not be mixed into backup-capable devices")

    view = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert_contains(view, "Finder-visible devices", "Empty device state should disclose devices Finder can see")
    assert_contains(view, "Nearby, Not Backup-Ready", "Finder-visible-only devices should have a distinct non-backup-ready state")
    assert_contains(view, "cannot open a usbmux connection", "UI should explain why Finder visibility is not enough")


def test_mobdev2_wireless_discovery_is_a_non_backup_hint(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, '["bonjour", "mobdev2", "--timeout", "3"]', "wireless discovery should query pymobiledevice3 mobdev2 with a bounded browse timeout")
    assert_contains(src, "parseMobdev2DeviceEntries", "mobdev2 JSON should be parsed into typed device entries")
    assert_contains(src, 'entry["UniqueDeviceID"] as? String', "mobdev2 discovery must use the real device UDID")
    assert_contains(src, 'discoveryMethod: "mobdev2"', "mobdev2 entries should preserve their discovery method")
    assert_contains(src, "mobdev2Devices.map", "mobdev2 metadata should feed Finder-visible nearby-device hints")
    assert_contains(src, "still a discovery hint", "mobdev2 devices should not be treated as backup-capable targets")
    assert_not_contains(src, 'args.append("--mobdev2")', "pymobiledevice3 backup must not invoke interactive mobdev2 in a non-TTY app")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "cachedBonjourDevices", "DeviceManager should show mobdev2/Finder-visible devices as nearby hints")
    assert_contains(manager, "connectedDevices = []", "mobdev2-only devices should not be mixed into backup-capable devices")

    backup = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(backup, "preferNetwork: preferNetwork", "BackupManager should thread Wi-Fi preference into pymobiledevice3 backup")


def test_finder_wifi_sync_can_be_enabled_from_usb_device(root: Path) -> None:
    py = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(py, '"lockdown", "wifi-connections", "--state"', "Phosphor should call pymobiledevice3's Finder-style Wi-Fi toggle")
    assert_contains(py, 'enabled ? "on" : "off"', "Wi-Fi connection toggle should support the on state explicitly")
    assert_contains(py, "run while the device is reachable over USB/lockdown", "Wi-Fi enablement should be documented as USB/lockdown-only")
    assert_contains(py, "normalizeLockdownResult", "pymobiledevice3 lockdown commands can emit ERROR on stderr with exit code 0 and must be normalized")
    assert_contains(py, '"device not found"', "Wi-Fi enablement must not falsely succeed when pymobiledevice3 reports Device not found")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "func enableWiFiConnections(udid", "DeviceManager should expose Wi-Fi connection enablement")
    assert_contains(manager, "setWiFiConnections(udid: udid, enabled: true)", "DeviceManager should run the actual lockdown Wi-Fi toggle")
    assert_contains(manager, "pairing alone\n        // is not enough", "Pairing must not be treated as successful Wi-Fi enablement")
    assert_contains(manager, "invalidateConnectionCaches(for: udid)", "Successful Wi-Fi enablement should invalidate cached connection metadata")

    wifi = read(root, "Sources/Phosphor/Services/WiFiConnectionManager.swift")
    assert_contains(wifi, "setWiFiConnections(udid: udid, enabled: true)", "WiFiConnectionManager should use the Finder-style toggle")
    assert_not_contains(wifi, "if await PyMobileDevice.pair(udid: udid) { return true }", "Pairing alone should not report Wi-Fi sync enabled")

    vm = read(root, "Sources/Phosphor/ViewModels/DeviceViewModel.swift")
    assert_contains(vm, "guard device.connectionType == .usb", "UI flow should only enable Wi-Fi from a USB-connected device")
    assert_contains(vm, "Wi-Fi connection enabled. Unplug the cable", "Success copy should tell the user to unplug and rescan")

    view = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert_contains(view, "Enable Wi-Fi", "Device overview should surface a Wi-Fi enable action")
    assert_contains(view, "Show this iPhone when on Wi-Fi", "UI copy should tie the action to Finder's setting")
    assert_contains(view, "@EnvironmentObject var backupVM", "Device overview should be able to start backups directly")
    assert_contains(view, "Start a backup for this device", "Device overview should surface a backup action")
    assert_contains(view, "Full Wi-Fi Backup?", "Device overview Wi-Fi full backups should use the same safety confirmation pattern")
    assert_contains(view, "BackupManager.hasExistingBackup(for: device.id) && backupVM.backups.contains", "Device overview should only run incremental Wi-Fi backups when complete metadata exists")
    assert_contains(view, "value: activity.displayProgressFraction", "Device overview backup progress should use a device-scoped linear loading bar")
    assert_contains(view, "activity.displayProgressText", "Device overview should show sanitized device-scoped backup progress copy")


def test_backup_progress_ui_uses_sanitized_loading_bar(root: Path) -> None:
    backup_vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    backup_view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(backup_vm, "var displayProgressText", "BackupViewModel should expose user-facing progress copy")
    assert_contains(backup_vm, "return \"Backing up", "Backup progress copy should say Backing up, not the backend/protocol name")
    assert_contains(backup_vm, "var displayProgressFraction", "BackupViewModel should expose progress for a loading bar")
    assert_contains(backup_view, "value: activity.displayProgressFraction", "Backup list should show a linear loading bar for every active device")
    assert_contains(backup_view, "activity.displayProgressText", "Backup list should not show raw backend/protocol progress text")
    assert_contains(manager, "onProgress(\"Backing up", "pymobiledevice3 stderr percentage updates should reach the user-facing progress bar")


def test_current_iphone_model_identifiers_are_mapped(root: Path) -> None:
    device = read(root, "Sources/Phosphor/Models/DeviceInfo.swift")
    parser = read(root, "Sources/Phosphor/Utilities/PlistParser.swift")
    for src_name, src in (("DeviceInfo", device), ("PlistParser", parser)):
        assert_contains(src, '"iPhone18,1": "iPhone 17 Pro"', f"{src_name} should map iPhone18,1 correctly")
        assert_contains(src, '"iPhone18,2": "iPhone 17 Pro Max"', f"{src_name} should map iPhone18,2 correctly")
        assert_contains(src, '"iPhone18,3": "iPhone 17"', f"{src_name} should map iPhone18,3 correctly")
        assert_contains(src, '"iPhone18,4": "iPhone Air"', f"{src_name} should map iPhone18,4 correctly")
        assert_contains(src, '"iPhone18,5": "iPhone 17e"', f"{src_name} should map iPhone18,5 correctly")


def test_device_entry_merge_prefers_usb_without_dropping_network_only(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    merge = re.search(r"private static func mergeDeviceEntries\(_ entries: \[DeviceEntry\]\).*?\n    \}", src, re.S)
    assert merge is not None, "PyMobileDevice.mergeDeviceEntries should exist"
    body = merge.group(0)
    assert_contains(body, "orderedUdids", "merge should preserve stable discovery order")
    assert_contains(body, 'connectionType != "USB" || entry.connectionType == "USB"', "merge should prefer USB when both transports are visible")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "deviceInfoCache.removeAll()", "zero-device scans should clear stale device cache")
    assert_contains(manager, "bonjourDeviceCache = nil", "zero-device scans should clear stale nearby-device cache")


def test_sidebar_highlights_only_the_selected_or_hovered_device_row(root: Path) -> None:
    sidebar = read(root, "Sources/Phosphor/Views/SidebarView.swift")
    assert_contains(sidebar, "@State private var hoveredDeviceID: String?", "device hover state must identify one device row")
    assert_contains(sidebar, "isVisuallySelected: isSelected", "each device row must pass its own selected state to the shared button")
    assert_contains(sidebar, "isVisuallyHovered: hoveredDeviceID == device.id", "only the hovered device row should receive hover styling")
    assert_contains(sidebar, "else if hoveredDeviceID == device.id", "a stale hover-exit event must not clear a newer device row hover")


def test_device_polling_prefers_lightweight_discovery_before_python_fallback(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "let lightweightScan = await listLibimobiledeviceEntries()", "routine polling should start with lightweight idevice_id discovery")
    # The `!lightweightScan.isAvailable` term is not decoration. On a
    # pymobiledevice3-only install libimobiledevice discovery yields nothing, so
    # without it every poll where the compatibility scan is not yet due renders
    # an empty device list and drops the sidebar selection. Regressed once
    # already; commit 2b654c3 added this assertion for exactly that reason.
    assert_contains(manager, "if forceRefresh || !lightweightScan.isAvailable || compatibilityScanIsDue", "routine polls must still run the compatibility probe when libimobiledevice is unavailable")
    assert_contains(manager, "DiscoveryRetryBackoff(initialDelay: 5, maximumDelay: 30)", "routine polling should periodically recheck pymobiledevice-specific discovery")
    assert_contains(manager, "compatibilityScanIsDue", "devices visible only to pymobiledevice must still be discovered automatically")
    assert_contains(manager, "let pyDiscovery = await PyMobileDevice.discoverDevicesWithType()", "pymobiledevice discovery must return probe authority as well as entries")
    assert manager.index("let lightweightScan = await listLibimobiledeviceEntries()") < manager.index("let pyDiscovery = await PyMobileDevice.discoverDevicesWithType()"), "lightweight discovery must run before the expensive Python fallback"
    assert_not_contains(manager, "cachedNetworkDeviceEntries", "listDevicesWithType already queries network devices; polling must not launch a duplicate network query")
    assert_contains(manager, "Shell.runAsync(\"idevice_id\", arguments: [\"-l\"], timeout: 5)", "routine USB discovery must be timeout bounded")
    assert_contains(manager, "Shell.runAsync(\"idevice_id\", arguments: [\"-n\"], timeout: 5)", "routine network discovery must be timeout bounded")
    assert_contains(manager, "compatibilityOnlyDeviceCache", "pymobiledevice-only devices must persist between compatibility scans")
    assert_contains(manager, "currentCompatibilityEntries = pyEntries.filter", "compatibility cache should exclude devices already covered by lightweight discovery")
    assert_contains(manager, "lightweightScan.entries + retainedEntries", "every routine poll should merge non-expired compatibility-only devices")

    # Pin the actual predicate and the merge expression. Asserting against a Python
    # restatement of the intended semantics stays green no matter what the Swift does.
    assert_contains(
        manager,
        "currentCompatibilityEntries = pyEntries.filter { !lightweightIDs.contains($0.udid) }",
        "the compatibility cache must keep the devices lightweight discovery MISSED, not the ones it already found",
    )
    # A failed idevice_id probe yields an empty UDID set, so the subtraction above is
    # a no-op and would cache every USB device as compatibility-only, republishing
    # them as duplicate rows for a full interval once the probe recovers.
    assert_contains(manager, "if lightweightScan.isAvailable {", "the compatibility cache may only be refreshed from a scan whose lightweight probe succeeded")
    assert_contains(manager, "compatibilityOnlyDeviceCache.reset()", "an authoritative full pymobiledevice snapshot must clear stale compatibility-only entries when lightweight discovery is unavailable")
    assert_contains(manager, "pyEntries + retainedEntries", "a partial pymobiledevice failure must retain non-expired compatibility-only entries")
    assert_contains(manager, "authoritative: pyDiscovery.isAuthoritative", "only an authoritative transport snapshot may delete cached compatibility-only entries")
    assert_contains(manager, "regularInterval: compatibilityDiscoveryInterval", "a successful compatibility scan should restore the normal scan interval")
    assert_contains(manager, "lastError = pyDiscovery.failureDescription", "a partial compatibility scan should be surfaced instead of masquerading as an empty result")
    assert_contains(manager, "compatibilityDiscoveryRetry.isDue(at: scanStartedAt)", "the first poll should run immediately and later failures should honor retry backoff")
    assert_not_contains(manager, "isAvailable: usb.succeeded && network.succeeded", "requiring the -n probe to succeed disables the optimization on builds whose idevice_id rejects it")


def test_wifi_schedules_use_network_discovery_and_network_backup_flag(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    assert_contains(scheduler, "pyEntries.filter { $0.connectionType != \"USB\" }", "Wi-Fi-only schedules should filter out USB pymobiledevice entries")
    assert_contains(scheduler, "PyMobileDevice.listNetworkDevices()", "Wi-Fi-only schedules should probe network devices explicitly")
    assert_contains(scheduler, "libimobiledeviceCandidates(wifiOnly:", "scheduled fallback should classify both USB and network candidates")
    assert_contains(scheduler, 'arguments: ["-n"], timeout: 5', "scheduled fallback should query timeout-bounded network discovery")
    assert_contains(scheduler, 'arguments: ["-l"], timeout: 5', "any-transport schedules should still prefer an available USB route")
    assert_contains(scheduler, "createBackup(udid: udid, incremental: incremental, preferNetwork: preferNetwork)", "all scheduled backups should preserve incremental and network preferences through the shared queue")
    assert_contains(scheduler, "runSchedule.incrementalOnly && BackupManager.hasExistingBackup(for: udid)", "Scheduled incremental mode should run the required first full backup when metadata is missing")
    assert_contains(scheduler, "running required first full backup", "Scheduled first-full fallback should be logged clearly")
    assert_contains(scheduler, "scheduleDidChangeNotification", "App-level scheduler should react when another window enables a schedule after launch")
    assert_contains(scheduler, "self.configureMonitoring()", "schedule changes should reconfigure monitoring without an idle disabled timer")
    assert_contains(scheduler, "if candidate.nextRunDate == nil", "Scheduler should initialize every enabled device schedule after a separate UI instance changes it")
    assert_contains(scheduler, "func scheduledTime(on date: Date) -> Date", "Scheduler should align non-hourly next runs to preferred wall-clock time")
    assert_contains(scheduler, "components.hour = schedule.preferredHour", "Scheduler should use preferred hour even after a previous run exists")
    assert_contains(scheduler, "components.minute = schedule.preferredMinute", "Scheduler should use preferred minute even after a previous run exists")
    assert_contains(scheduler, "while next <= now", "Scheduler should advance preferred-time candidates until they are in the future")
    assert_not_contains(scheduler, "next = lastRun.addingTimeInterval(schedule.frequency.interval)", "Scheduler should not drift nextRunDate to the last completion time")
    run_now = scheduler.split("func runNow() async", 1)[1].split("private func run(", 1)[0]
    assert run_now.index("scheduledRunOwnership.claim(identity: scheduleIdentity, runID: runID)") < run_now.index("await run("), "Run Now should claim its device schedule before async discovery"

    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "Wi-Fi only (skip if Wi-Fi is not available)", "Wi-Fi-only schedule copy should not say USB is required")
    assert_contains(view, "Incremental when possible (faster)", "Schedule copy should not promise incremental-only behavior when first run may be full")
    assert_contains(view, "first scheduled run will create the required full backup", "Schedule UI should explain first-run behavior for incremental mode")
    assert_not_contains(view, "scheduler.startMonitoring()", "Schedule sheets should not start duplicate schedulers separate from the app-level monitor")
    assert_contains(view, ".onChange(of: scheduler.schedule.preferredHour)", "Schedule sheet should refresh next-run timing when preferred time changes")

    settings = read(root, "Sources/Phosphor/Views/Settings/SettingsView.swift")
    assert_contains(settings, "Wi-Fi only (skip if Wi-Fi is not available)", "Settings schedule copy should match the safer schedule sheet copy")
    assert_contains(settings, "Incremental when possible (faster)", "Settings should not promise incremental-only behavior when first run may be full")
    assert_contains(settings, ".onChange(of: scheduler.schedule.preferredHour)", "Settings should refresh next-run timing when preferred time changes")


def test_background_wake_rearms_every_enabled_device_schedule_through_shared_view_model(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")

    monitoring = scheduler.split("private func configureMonitoring()", 1)[1].split("func stopMonitoring()", 1)[0]
    assert_contains(monitoring, "NSBackgroundActivityScheduler(", "enabled schedules need a macOS background wake source")
    assert_contains(monitoring, "repeats = true", "background wakes must rearm instead of becoming a one-shot timer")
    assert_contains(monitoring, "await self?.checkAndRun()", "a background wake must use the scheduler's normal all-schedules evaluation")

    check_and_run = scheduler.split("func checkAndRun() async", 1)[1].split("func runNow() async", 1)[0]
    assert_contains(check_and_run, "for stored in schedules where stored.enabled", "wake evaluation must retain every enabled device schedule")
    assert_contains(check_and_run, "for dueSchedule in dueSchedules", "each due target must be started independently after a wake")
    assert_contains(check_and_run, "self?.startScheduledRun(dueSchedule)", "wake evaluation must preserve per-device scheduled-run ownership")

    scheduled_run = scheduler.split("private func runScheduledBackup(", 1)[1].split("// MARK: - Device Discovery", 1)[0]
    assert_contains(scheduled_run, "await backupViewModel.createBackup", "background scheduled runs must stay on the shared BackupViewModel queue")
    assert_not_contains(scheduled_run, "BackupManager(", "background scheduled runs must not create a private backup manager")


def test_scheduled_backups_never_choose_between_multiple_devices(root: Path) -> None:
    resolver = root / "Sources/Phosphor/Utilities/ScheduledBackupTargetResolver.swift"
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    schedule_sheet = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    settings = read(root, "Sources/Phosphor/Views/Settings/SettingsView.swift")

    assert_contains(scheduler, "ScheduledBackupTargetResolver.resolve", "scheduled backup discovery must use the fail-closed target resolver")
    assert_contains(scheduler, "Multiple devices are available. Choose a device", "ambiguous discovery should explain why no backup started")
    assert_not_contains(scheduler, "if let first = eligiblePyEntries.first", "scheduled backups must not pick the first enumerated device")
    assert_not_contains(scheduler, "if let first = devices.first", "libimobiledevice fallback must not pick the first enumerated device")
    assert_contains(schedule_sheet, "ScheduledBackupDevicePicker", "the backup schedule sheet should expose an explicit device picker")
    assert_contains(settings, "ScheduledBackupDevicePicker", "Settings should expose the same explicit device picker")

    probe = r'''
import Foundation

typealias Resolver = ScheduledBackupTargetResolver

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

let phone = Resolver.Candidate(udid: "phone", preferNetwork: true)
let tablet = Resolver.Candidate(udid: "tablet", preferNetwork: false)

require(Resolver.resolve(candidates: [], targetUDID: nil) == .noneAvailable, "zero devices must remain unavailable")
require(Resolver.resolve(candidates: [phone], targetUDID: nil) == .target(phone), "one legacy device may remain automatic")
require(Resolver.resolve(candidates: [phone, tablet], targetUDID: nil) == .selectionRequired, "multiple devices must require selection")
require(Resolver.resolve(candidates: [tablet, phone], targetUDID: nil) == .selectionRequired, "discovery order must not select a target")
require(Resolver.resolve(candidates: [phone, tablet], targetUDID: "tablet") == .target(tablet), "an explicit target must win")
require(Resolver.resolve(candidates: [phone], targetUDID: "tablet") == .noneAvailable, "a missing target must not fall back to another device")

let phoneUSB = Resolver.Candidate(udid: "phone", preferNetwork: false)
require(Resolver.resolve(candidates: [phone, phoneUSB], targetUDID: nil) == .target(phoneUSB), "duplicate transports are one device and USB should win")
'''

    with tempfile.TemporaryDirectory(prefix="phosphor-schedule-target-") as temp_dir:
        temp = Path(temp_dir)
        main = temp / "main.swift"
        binary = temp / "target-resolver-probe"
        main.write_text(probe)
        compile_result = subprocess.run(
            ["swiftc", str(resolver), str(main), "-o", str(binary)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, f"target resolver probe should compile: {compile_result.stderr}"
        run_result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        assert run_result.returncode == 0, f"target resolver behavior failed: {run_result.stderr}"


def test_legacy_schedule_resolves_the_complete_discovery_union(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    discovery = "var discoveredCandidates" + scheduler.split("var discoveredCandidates", 1)[1].split("// MARK: - Scheduling Math", 1)[0]

    assert_contains(discovery, "var discoveredCandidates", "legacy target discovery should accumulate candidates across backends")
    assert_contains(discovery, "discoveredCandidates.append(contentsOf:", "every applicable discovery backend should contribute to one candidate union")
    assert_contains(discovery, "resolveTarget(from: discoveredCandidates, targetUDID: runSchedule.targetUDID)", "legacy target resolution must happen once against the complete candidate union")
    resolve_call = "resolveTarget(from: discoveredCandidates, targetUDID: runSchedule.targetUDID)"
    assert discovery.rindex(resolve_call) > discovery.index("PyMobileDevice.listNetworkDevices()"), "network discovery must finish before resolving a legacy target"
    assert discovery.rindex(resolve_call) > discovery.index("await libimobiledeviceCandidates"), "libimobiledevice fallback must finish before resolving a legacy target"

    # A single primary candidate plus a distinct fallback candidate is ambiguous.
    # This is the cross-backend scenario that previously selected the primary early.
    resolver = root / "Sources/Phosphor/Utilities/ScheduledBackupTargetResolver.swift"
    probe = r'''
import Foundation

let primary = ScheduledBackupTargetResolver.Candidate(udid: "phone", preferNetwork: true)
let fallback = ScheduledBackupTargetResolver.Candidate(udid: "tablet", preferNetwork: true)
precondition(
    ScheduledBackupTargetResolver.resolve(
        candidates: [primary, fallback],
        targetUDID: nil
    ) == .selectionRequired
)

let single = ScheduledBackupTargetResolver.resolve(candidates: [
    .init(udid: "phone-a", preferNetwork: true)
], targetUDID: nil)
precondition(single == .target(.init(udid: "phone-a", preferNetwork: true)))

let usbPreferred = ScheduledBackupTargetResolver.resolve(candidates: [
    .init(udid: "phone-a", preferNetwork: true),
    .init(udid: "phone-a", preferNetwork: false)
], targetUDID: "phone-a")
precondition(usbPreferred == .target(.init(udid: "phone-a", preferNetwork: false)))
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-schedule-union-") as temp_dir:
        temp = Path(temp_dir)
        main = temp / "main.swift"
        binary = temp / "schedule-union-probe"
        main.write_text(probe)
        result = subprocess.run(["swiftc", str(resolver), str(main), "-o", str(binary)], capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr


def test_multi_device_backup_queue_limits_concurrency_and_deduplicates_devices(root: Path) -> None:
    queue_source = root / "Sources/Phosphor/Utilities/BackupJobQueue.swift"
    assert queue_source.exists(), "multi-device backups need a behaviorally testable queue"
    probe = r'''
import Foundation

@main
struct BackupQueueProbe {
    static func main() {
        var queue = BackupJobQueue(maxConcurrent: 2)

        precondition(queue.enqueue(udid: "phone") == .started)
        precondition(queue.enqueue(udid: "tablet") == .started)
        precondition(queue.enqueue(udid: "spare") == .queued(position: 1))
        precondition(queue.enqueue(udid: "phone") == .duplicate)
        precondition(queue.runningUDIDs == Set(["phone", "tablet"]))
        precondition(queue.queuedUDIDs == ["spare"])

        precondition(queue.finish(udid: "phone") == "spare")
        precondition(queue.runningUDIDs == Set(["tablet", "spare"]))
        precondition(queue.finish(udid: "missing") == nil)

        precondition(queue.enqueue(udid: "fourth") == .queued(position: 1))
        precondition(queue.cancel(udid: "fourth") == .removedQueued)
        precondition(queue.cancel(udid: "tablet") == .cancelRunning)
        precondition(queue.cancel(udid: "missing") == .notFound)
        print("PASS")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-backup-queue-") as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        binary_path = temp / "backup-queue-probe"
        probe_path.write_text(probe)
        result = subprocess.run(
            ["swiftc", "-parse-as-library", str(queue_source), str(probe_path), "-o", str(binary_path)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "PASS"


def test_backup_view_model_tracks_and_cancels_jobs_per_device(root: Path) -> None:
    view_model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert_contains(view_model, "@Published private(set) var backupActivities: [String: BackupActivity]", "backup activity must be keyed by device")
    assert_contains(view_model, "private var backupManagers: [String: BackupManager]", "each running device needs an independent process owner")
    assert_contains(view_model, "BackupJobQueue(maxConcurrent: 2)", "the app should run at most two device backups concurrently")
    assert_contains(view_model, "func cancelBackup(udid: String)", "each device needs its own cancellation entry point")
    assert_contains(view_model, "manager.cancelBackup()", "cancelling one device must not terminate another device's process")
    assert_contains(view_model, "backupJobTasks[udid]?.cancel()", "a promoted job must remain cancellable before its BackupManager exists")
    assert_contains(view_model, "backupJobTasks[nextUDID] = task", "promotion must register task ownership before the job can start")
    assert_contains(view_model, "withTaskCancellationHandler", "cancelling a scheduled task must propagate into its queue request")
    assert_contains(view_model, "BackupRequestTracker", "deduplicated callers need request ownership before cancellation can affect a shared job")
    assert_contains(view_model, "let encrypted: Bool", "queued backup requests must retain encryption intent")
    assert_contains(view_model, "func activity(for udid: String)", "device views need device-scoped progress")
    create = view_model.split("func createBackup(udid: String", 1)[1].split("private func", 1)[0]
    assert "guard !isCreating" not in create, "a global creation guard would block a second device"
    assert_contains(create, "jobQueue.enqueue(udid: udid)", "backup requests should enter the bounded per-device queue")


def test_backup_request_cancellation_respects_deduplicated_callers(root: Path) -> None:
    tracker_source = root / "Sources/Phosphor/Utilities/BackupRequestTracker.swift"
    assert tracker_source.exists(), "queue cancellation needs a behaviorally testable request-ownership model"
    probe = r'''
import Foundation

@main
struct BackupRequestTrackerProbe {
    static func main() {
        var tracker = BackupRequestTracker()
        let owner = UUID()
        let waiter = UUID()

        tracker.registerOwner(owner, udid: "phone")
        precondition(tracker.cancel(owner, udid: "phone") == .cancelJob)
        tracker.finish(udid: "phone")

        tracker.registerOwner(owner, udid: "phone")
        tracker.registerWaiter(waiter, udid: "phone")
        var ownerCompletions: [String: UUID] = ["phone": owner]
        var ownerResumeCount = 0
        var jobCancelCount = 0
        for _ in 0..<2 {
            switch tracker.cancel(owner, udid: "phone") {
            case .detachRequest:
                if ownerCompletions["phone"] == owner {
                    ownerCompletions.removeValue(forKey: "phone")
                    ownerResumeCount += 1
                }
            case .cancelJob:
                jobCancelCount += 1
            case .notFound:
                break
            }
        }
        precondition(ownerResumeCount == 1, "a detached owner continuation must resume exactly once")
        precondition(jobCancelCount == 0, "the shared job must continue while a waiter authorizes it")
        precondition(tracker.cancel(waiter, udid: "phone") == .cancelJob)
        jobCancelCount += 1
        precondition(jobCancelCount == 1)
        tracker.finish(udid: "phone")

        tracker.registerOwner(owner, udid: "phone")
        tracker.registerWaiter(waiter, udid: "phone")
        precondition(tracker.cancel(waiter, udid: "phone") == .detachRequest)
        precondition(tracker.cancel(owner, udid: "phone") == .cancelJob)
        precondition(tracker.cancel(UUID(), udid: "phone") == .notFound)
        print("PASS")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-backup-request-tracker-") as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        binary_path = temp / "backup-request-tracker-probe"
        probe_path.write_text(probe)
        result = subprocess.run(
            ["swiftc", "-parse-as-library", str(tracker_source), str(probe_path), "-o", str(binary_path)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "PASS"


def test_backup_surfaces_show_stable_device_identity(root: Path) -> None:
    model = read(root, "Sources/Phosphor/Models/BackupInfo.swift")
    backup_list = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    browser = read(root, "Sources/Phosphor/Views/Backup/BackupBrowserView.swift")
    time_machine = read(root, "Sources/Phosphor/Views/Backup/BackupTimeMachineView.swift")
    unlock = read(root, "Sources/Phosphor/Views/Backup/BackupUnlockSheet.swift")
    archiver = read(root, "Sources/Phosphor/Services/BackupArchiver.swift")
    apps = read(root, "Sources/Phosphor/Views/Apps/AppManagerView.swift")
    messages = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")

    assert_contains(model, "var shortUDID", "backup metadata should expose a stable physical-device discriminator")
    assert_contains(model, "let source = !udid.isEmpty ? udid", "the visible discriminator should prefer the authoritative backup UDID")
    assert_contains(model, "var deviceIdentityLabel", "all backup pickers should share one device identity label")
    assert_contains(model, "deviceName", "the identity label should retain the friendly device name")
    assert_contains(model, "modelName", "the identity label should distinguish devices by model when possible")
    assert_contains(model, "shortUDID", "same-name and same-model devices still need a unique visible suffix")

    for source, surface in [
        (backup_list, "backup list"),
        (browser, "backup browser"),
        (time_machine, "backup history"),
        (unlock, "encrypted-backup prompt"),
        (apps, "Apps backup picker"),
        (messages, "Messages backup picker"),
    ]:
        assert_contains(source, "backup.deviceIdentityLabel", f"{surface} should identify which physical device owns the backup")
    assert_contains(apps, "$0.deviceIdentityLabel", "the closed Apps picker must retain the selected device discriminator")
    assert_contains(messages, "$0.deviceIdentityLabel", "the closed Messages picker must retain the selected device discriminator")
    assert_contains(backup_list, "backedUpDeviceCount", "the backup list should report how many distinct devices it contains")
    assert_contains(archiver, "backup.shortUDID", "portable archive filenames should remain attributable when two devices share a name")
    assert_contains(time_machine, "request.targetUDID.suffix(8)", "restore confirmation must identify the exact destination device")
    assert_contains(time_machine, "request.backup.deviceIdentityLabel", "restore confirmation must identify the exact source backup")

    probe = r'''
import Foundation

struct BackupInfoPlist {
    let deviceName: String
    let displayName: String
    let productType: String
    let productVersion: String
    let buildVersion: String
    let serialNumber: String
    let udid: String
    let iccid: String?
    let imei: String?
    let meid: String?
    let phoneNumber: String?
    let lastBackupDate: Date?
    let isEncrypted: Bool
    var modelName: String { productType }
}
struct BackupStatusProbe { let date: Date?; let isFullBackup: Bool }
struct BackupManifestProbe { let isEncrypted: Bool; let applicationBundleIds: [String] }
enum PlistParser {
    static func parseBackupInfo(_ path: String) -> BackupInfoPlist? { nil }
    static func parseBackupStatus(_ path: String) -> BackupStatusProbe? { nil }
    static func parseManifest(_ path: String) -> BackupManifestProbe? { nil }
}
extension FileManager { func directorySize(at path: String) -> UInt64 { 0 } }
extension UInt64 { var formattedFileSize: String { "0 B" } }
extension Date {
    var shortString: String { "date" }
    var relativeString: String { "relative" }
}

@main
struct Probe {
    static func backup(id: String? = nil, udid: String, serial: String = "serial") -> BackupInfo {
        BackupInfo(
            id: id ?? udid,
            path: "/tmp/\(udid)",
            deviceName: "My iPhone",
            displayName: "My iPhone",
            productType: "iPhone17,1",
            iosVersion: "18.0",
            serialNumber: serial,
            udid: udid,
            lastBackupDate: nil,
            isEncrypted: false,
            isFullBackup: true,
            size: 0,
            sizeResolved: true,
            appCount: 0
        )
    }

    static func main() {
        let phone = backup(udid: "00000000AAAAAAAA")
        let tablet = backup(udid: "00000000BBBBBBBB")
        precondition(phone.deviceIdentityLabel != tablet.deviceIdentityLabel)
        precondition(phone.deviceIdentityLabel.contains("AAAAAAAA"))
        precondition(tablet.deviceIdentityLabel.contains("BBBBBBBB"))
        precondition(phone.shortUDID == "AAAAAAAA")
        let legacyPhone = backup(id: "folder-11111111", udid: "", serial: "serial-11111111")
        let legacyTablet = backup(id: "folder-22222222", udid: "", serial: "serial-22222222")
        precondition(legacyPhone.deviceIdentityLabel != legacyTablet.deviceIdentityLabel)
        precondition(legacyPhone.deviceIdentityLabel.contains("11111111"))
        precondition(legacyTablet.deviceIdentityLabel.contains("22222222"))
        print("PASS")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-backup-identity-") as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        binary_path = temp / "backup-identity-probe"
        probe_path.write_text(probe)
        result = subprocess.run(
            ["swiftc", str(root / "Sources/Phosphor/Models/BackupInfo.swift"), str(probe_path), "-o", str(binary_path)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "PASS"


def test_multi_device_backup_activity_is_visible_and_device_scoped(root: Path) -> None:
    view_model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    backup_list = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    overview = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")

    assert_contains(view_model, "func isBackupActive(for udid: String)", "action gating should be scoped to one device")
    assert_contains(backup_list, "activeBackupActivities", "the Backups screen should render all active and queued devices")
    assert_contains(backup_list, "deviceIdentity(for: activity.udid)", "same-name devices need a visible UDID discriminator while backing up")
    assert_contains(backup_list, "backupVM.cancelBackup(udid: activity.udid)", "each activity row needs its own cancel action")
    assert_contains(overview, "backupVM.activity(for: device.id)", "a device card must not show another device's progress")
    assert_contains(overview, 'backupVM.isBackupActive(for: device.id) ? "Backing Up..."', "a device card must not show another device's global backup label")
    assert_contains(overview, ".disabled(backupVM.isBackupActive(for: device.id))", "only the busy device's backup button should be disabled")
    assert "backupVM.isCreating" not in app.split('CommandMenu("Backup")', 1)[1].split('Button("Refresh Backups")', 1)[0], "Cmd-B should remain available when another device is backing up"


def test_schedules_are_persisted_and_executed_per_device(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    settings = read(root, "Sources/Phosphor/Views/Settings/SettingsView.swift")
    backup_list = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")

    assert_contains(scheduler, "@Published private(set) var schedules: [Schedule]", "scheduler should retain independent per-device schedules")
    assert_contains(scheduler, 'schedulesKey = "phosphor.backup.schedules"', "multiple schedules need a new persistence key")
    assert_contains(scheduler, "JSONDecoder().decode([Schedule].self", "new installs should restore all device schedules")
    assert_contains(scheduler, "JSONDecoder().decode(Schedule.self", "the previous single schedule must migrate without data loss")
    assert_contains(scheduler, "func selectSchedule(targetUDID:", "schedule surfaces need to switch between device configurations")
    assert_contains(scheduler, "for dueSchedule in dueSchedules", "all due device schedules should be considered in one monitor tick")
    assert_contains(scheduler, "withTaskGroup", "different due devices should be allowed to enter the bounded shared queue together")
    assert_not_contains(scheduler, "targetDiscoveryFailure", "concurrent device discovery must not share one mutable failure message")
    assert_contains(scheduler, "backupViewModel.createBackup", "scheduled jobs must share the app-wide two-device queue")
    assert_contains(scheduler, "guard let backupViewModel else", "scheduled jobs must fail closed if the shared queue is unavailable")
    assert_not_contains(scheduler, "let manager = BackupManager()", "scheduled jobs must never bypass the shared bounded queue")
    assert_contains(scheduler, "latestPersistedSchedules()", "separate schedule windows must merge instead of overwriting another device's saved schedule")
    assert_contains(scheduler, "scheduleDidChangeNotification", "all open schedule editors must refresh after another instance saves")
    assert_contains(scheduler, "mergeEditedFields", "stale editors must apply only fields the user actually changed")
    assert_contains(scheduler, "guard schedules.contains(where: \\.enabled)", "disabled schedules must not keep an idle polling timer alive")
    assert_contains(scheduler, "latestSchedule(matching: runSchedule.targetUDID)", "a completed run must preserve edits made while that device backup was active")
    assert_contains(app, "scheduler.attachBackupViewModel(backupVM)", "the app monitor must use the shared backup activity center")
    assert_contains(settings, "scheduler.selectSchedule", "Settings should load the selected device's independent schedule")
    assert_contains(backup_list, "scheduler.selectSchedule", "the schedule sheet should load the selected device's independent schedule")
    assert_contains(backup_list, "ScheduledBackupDevicePicker", "the backup schedule sheet should share the identity-safe device picker")
    picker = read(root, "Sources/Phosphor/Views/Backup/ScheduledBackupDevicePicker.swift")
    assert_contains(picker, "device.id.suffix(8)", "same-name devices must be distinguishable in schedule target selection")


def test_incremental_backups_require_existing_metadata(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "hasExistingBackup(for udid", "BackupManager should expose an existing-backup metadata preflight")
    assert_contains(manager, "backupMetadataHealth(for udid", "BackupManager should distinguish complete, missing, and incomplete backup metadata")
    assert_contains(manager, "if Self.looksLikeBackupFolder(dir)", "Single-backup discovery should exclude Info.plist-only incomplete folders")
    assert_contains(manager, "guard Self.looksLikeBackupFolder(fullPath) else { continue }", "Backup discovery should exclude incomplete child backup folders")
    assert_contains(manager, "looksLikeBackupFolder(deviceDirectory) ? .complete : .incomplete", "Existing-backup preflight should require Info.plist and Manifest metadata")
    assert_contains(manager, "isNonEmptyFile(info)", "Completeness must require non-empty metadata; zero-length Info.plist stubs are an interrupted backup, not a complete one")
    assert_contains(manager, "Backup needs a full backup first", "Incremental backup should fail before backend calls when metadata is missing")
    assert_contains(manager, "Run a full backup first; future Wi-Fi backups can be incremental", "Missing metadata error should be actionable")
    assert_contains(manager, "deleteIncompleteBackup(for udid", "Recovery flow should be able to remove interrupted partial backup folders")
    assert_contains(manager, "expectedPath", "Incomplete-backup recovery should validate the exact failed path before moving anything")
    assert_contains(manager, "incompleteBackupHasKnownMarkers", "Incomplete-backup recovery should require recognizable iOS backup markers before moving a folder")
    assert_contains(manager, "trashItem", "Incomplete-backup recovery should move folders to Trash instead of permanently deleting them")
    assert_contains(manager, "finalizeSuccessfulBackup", "BackupManager should verify metadata before reporting backend exit 0 as success")
    assert_contains(manager, "Backup Metadata Incomplete", "Post-backup metadata verification failure should surface a structured recovery issue")
    assert_contains(manager, "let verified = self.finalizeSuccessfulBackup", "idevicebackup2 fallback success must also verify metadata before returning true")
    assert_not_contains(manager, "removeItem(atPath: path)", "Incomplete-backup recovery should not permanently delete backup folders")
    assert_contains(manager, "finalizeSuccessfulBackup", "Completed backup commands should be verified before the UI reports success")
    assert_contains(manager, "Backup Metadata Incomplete", "Post-backup verification should surface incomplete metadata as a structured failure")
    assert_contains(manager, "backupMetadataHealth(for: udid, in: directory)", "Post-backup verification should require complete metadata for the target device")

    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "shouldOfferIncremental(for: device)", "Backup UI should only offer incremental when a backup exists for the selected device")
    assert_contains(view, "BackupManager.hasExistingBackup(for: device.id) && backupVM.backups.contains", "Backup UI should require complete metadata before offering incremental")
    assert_contains(view, "First Wi-Fi Backup (Full)", "First Wi-Fi backup action should be full, not incremental")
    assert_contains(view, "Create Full Wi-Fi Backup", "Empty Wi-Fi backup state should default to a full backup")
    assert_contains(view, "First backup must be full", "Backup UI should explicitly explain first-backup state")
    assert_contains(view, "USB is recommended for the first backup", "Backup UI should recommend USB for first full backups")


def test_backup_failures_have_recovery_actions_and_collapsed_details(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "struct BackupFailure", "Backup failures should be structured for user-facing recovery UI")
    assert_contains(manager, "RecoveryAction", "Backup failures should carry recommended recovery actions")
    assert_contains(manager, "lastBackupFailure", "BackupManager should publish structured backup failures")
    assert_contains(manager, "technicalDetails", "Raw backend details should be separated from the short user-facing message")

    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert_contains(vm, "backupIssue", "BackupViewModel should surface structured backup issues separately from success alerts")
    assert_contains(vm, "retryBackup(for issue", "BackupViewModel should retry the device captured by the failed issue")
    assert_contains(vm, "failedBackupRequests[failure.id] = request", "concurrent failures must retain each device's exact transport/encryption request")
    assert_contains(vm, "deleteIncompleteBackupAndRunFull", "BackupViewModel should implement incomplete-backup recovery")
    assert_contains(vm, "runFullBackup(for issue", "Recovery actions should use the failed issue context, not the currently selected device")
    assert_contains(vm, "expectedPath: path", "Recovery deletion should use the exact path from the failed issue")
    assert_contains(vm, "private func clearBrowserState()", "BackupViewModel should clear stale browser state before opening another backup")
    assert_contains(vm, "selectedBackup = nil", "Failed backup browser opens should not leave stale selected backup state visible")
    assert_contains(vm, "browserDomains = []", "Failed backup browser opens should not leave stale domains visible")

    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "BackupIssueSheet", "Backup failures should use a sheet instead of dumping raw tracebacks in an alert")
    assert_contains(view, "handleBackupIssueAction(_ issue", "Backup recovery actions should receive the full failed issue context")
    assert_contains(view, "Move Incomplete Backup to Trash?", "Destructive incomplete-backup recovery should require explicit confirmation")
    assert_contains(view, "incompleteBackupTrashConfirmationMessage", "Incomplete-backup confirmation should show the exact path before moving it")
    assert_contains(view, "pendingIncompleteBackupIssue = issue\n            backupVM.backupIssue = nil\n            showIncompleteBackupTrashConfirm = true", "Incomplete-backup confirmation should dismiss the issue sheet before presenting the destructive confirmation")
    assert_contains(view, "DisclosureGroup(\"Technical details\"", "Technical details should be collapsed by default")
    assert_contains(view, "Delete Incomplete Backup & Run Full", "Incomplete backup failures should offer a recovery action")
    assert_contains(view, "Open Backup Settings", "Permission/folder failures should offer a settings action")

    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    assert_contains(app, "preferNetwork: device.connectionType == .wifi", "Backup menu command should preserve Wi-Fi network preference")
    assert_contains(app, "confirmFirstFullWiFiBackup", "Backup menu command should use the same first full Wi-Fi safety confirmation")
    assert_contains(app, "device.connectionType == .wifi && !BackupManager.hasExistingBackup", "Wi-Fi menu backups without metadata should be confirmed before starting")


def test_idevicebackup2_network_argument_order_is_before_backup_subcommand(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    match = re.search(r"private func idevicebackupArguments\(.*?\) -> \[String\] \{(?P<body>.*?)\n    \}", manager, re.S)
    assert match is not None, "idevicebackupArguments should centralize fallback argument order"
    body = match.group("body")
    assert_contains(body, 'var args = ["-u", udid]', "idevicebackup2 should start with the target UDID")
    assert body.index('if preferNetwork { args.append("-n") }') < body.index('args.append("backup")'), "idevicebackup2 -n must come before backup subcommand"
    assert body.index('args.append("backup")') < body.index('if full { args.append("--full") }'), "backup subcommand should come before --full"


def test_phosphor_archive_import_uses_active_dir_and_rejects_unsafe_archives(root: Path) -> None:
    archiver = read(root, "Sources/Phosphor/Services/BackupArchiver.swift")
    assert_contains(archiver, "MainActor.run { BackupManager.activeBackupDir }", "Archive import should use Phosphor's active backup directory, not Apple's protected MobileSync default")
    assert_contains(archiver, "archiveEntryIsSafe", "Archive import should validate tar entries before extraction")
    assert_contains(archiver, "guard !entry.hasPrefix(\"/\")", "Archive import should reject absolute tar paths")
    assert_contains(archiver, "!components.contains(\"..\")", "Archive import should reject parent-directory traversal entries")
    assert_contains(archiver, "topLevelEntries(in: entries).intersection(existingDirs)", "Archive import should not overwrite an existing backup directory")
    assert_contains(archiver, "normalizedEntryPath", "Archive import must normalize leading ./ so overwrite detection is not bypassable")
    assert_contains(archiver, 'subtracting(["."])', "Top-level entry set must drop the current-directory token so ./ entries map to their real directory")
    assert_contains(archiver, "isNonEmptyFile(info)", "Archive import completeness must require a non-empty Info.plist, not just its presence")
    assert_contains(archiver, "looksLikeBackupFolder(itemPath)", "Archive import should only report complete backup folders as imported")
    assert_contains(archiver, "moveImportedEntriesToTrash", "Failed archive imports should clean up newly extracted entries")
    assert_contains(archiver, "archive did not contain a complete iOS backup", "Invalid safe archives should fail with a clear reason")


def test_sidebar_device_rows_select_the_clicked_device(root: Path) -> None:
    sidebar = read(root, "Sources/Phosphor/Views/SidebarView.swift")
    assert_contains(sidebar, "onSelect: { deviceVM.selectDevice(device) }", "Each sidebar device row should select its own device, not the first device")
    assert_not_contains(sidebar, "selectDevice(first)", "Generic device sidebar action must not always select the first device")


def test_backup_selection_and_browser_navigation_stay_in_sync(root: Path) -> None:
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert_contains(vm, "reconcileSelectedBackupAfterReload", "Reloading backups should reconcile stale selected backup state")
    assert_contains(vm, "backups.contains(where: { $0.id == selectedBackup.id && $0.path == selectedBackup.path })", "Selected backup should remain valid only if the same backup path is still present")
    assert_contains(vm, "@discardableResult\n    func openBackupBrowser(_ backup: BackupInfo) -> Bool", "Opening a backup should report success so views can navigate only after manifest load")

    content = read(root, "Sources/Phosphor/Views/ContentView.swift")
    assert_contains(content, "BackupListView(onBrowseBackup: { selectedSection = .backupBrowser })", "Backup list Browse should navigate to Backup Browser after a successful open")
    assert_contains(content, "BackupTimeMachineView(onBrowseBackup: { selectedSection = .backupBrowser })", "Time Machine Browse should navigate to Backup Browser after a successful open")

    browser = read(root, "Sources/Phosphor/Views/Backup/BackupBrowserView.swift")
    assert_contains(browser, ".onChange(of: backupVM.selectedBackup?.id)", "Backup browser should clear local selections when the selected backup changes")
    assert_contains(browser, "selectedFiles.removeAll()", "Backup browser should drop selected file state when backup/domain changes")


def test_file_browser_delete_requires_confirmation_and_blocks_directories(root: Path) -> None:
    view = read(root, "Sources/Phosphor/Views/Files/FileBrowserView.swift")
    assert_contains(view, "pendingDeleteFile", "File browser delete should stage a pending file before confirmation")
    assert_contains(view, ".alert(\"Delete File?\"", "File browser delete should require a confirmation alert")
    assert_contains(view, "if !entry.isDirectory", "File browser should not expose directory deletion in the context menu")
    assert_not_contains(view, "Task { try? await fileManager.deleteFile(entry) }", "File browser context menu must not delete immediately")

    manager = read(root, "Sources/Phosphor/Services/FileTransferManager.swift")
    assert_contains(manager, "guard !entry.isDirectory", "FileTransferManager should reject directory deletion at the service layer")
    assert_contains(manager, "Directory deletion is not supported", "Directory deletion rejection should be explicit")


def test_backup_extract_preserves_domain_relative_paths(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "private func extractionRelativePath(for entry", "Backup extraction should centralize safe destination path construction")
    assert_contains(manager, "components = [safeDomain]", "Backup extraction should group files by domain to avoid basename collisions")
    assert_contains(manager, "entry.relativePath", "Backup extraction should preserve manifest relative paths instead of flattening to fileName")
    assert_contains(manager, 'safeDomain == "." || safeDomain == ".."', "Selective extraction must neutralize traversal domains so a crafted manifest row cannot escape the destination")
    assert_contains(manager, "Refusing to extract", "Selective extraction should refuse to write outside the destination folder")
    assert_not_contains(manager, "appendingPathComponent(entry.fileName)\n            do {", "Backup extraction should not flatten every selected file to destination/fileName")
    # Lexical sanitization cannot see a symlink that already exists in the chosen
    # folder; extractFile creates missing parents with withIntermediateDirectories,
    # which follows one. Selective extraction has to go through the shared resolver.
    assert_contains(manager, "SafeExtractionPath.prepareDestination", "Selective extraction must resolve destinations through SafeExtractionPath, not string joins")
    assert_not_contains(manager, "standardized.hasPrefix(destinationRoot)", "Prefix comparison against a root without a trailing separator also matches sibling directories")


def test_live_photo_exports_use_path_based_names(root: Path) -> None:
    live = read(root, "Sources/Phosphor/Services/LiveDeviceBrowser.swift")
    assert_contains(live, "private func uniqueLocalName(for photo", "Live photo export should centralize duplicate-safe local naming")
    assert_contains(live, "photo.path", "Live photo export naming should use the full device path, not only the basename")
    assert_contains(live, "replacingOccurrences(of: \"/\", with: \"_\")", "Live photo export should preserve DCIM folder identity in local filenames")
    assert_contains(live, "appendingPathComponent(uniqueLocalName(for: photo))", "Live photo temp cache and export should use duplicate-safe names")


def test_clearing_a_schedule_target_persists_a_disabled_clear_state(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    selection = scheduler.split("func selectSchedule(targetUDID:", 1)[1].split("// MARK: - Timer Control", 1)[0]

    assert_contains(selection, "if targetUDID == nil", "choosing the empty device picker option needs an explicit clear path")
    assert_contains(selection, "let previousTargetUDID = schedule.targetUDID", "clearing must identify the currently edited device schedule")
    assert_contains(selection, "schedules.removeAll", "clearing a target must remove the old per-device schedule from persisted schedules")
    assert_contains(selection, "schedule = Schedule()", "clearing a target must persist a disabled, targetless editor state")
    assert_contains(selection, "saveSchedules()", "clearing a target must write through to UserDefaults before reload")

    # Behavioral model of the persistence contract: after a user clears Device,
    # reloading must not rediscover the formerly enabled target schedule.
    schedules = [{"target": "phone", "enabled": True}]
    previous_target = "phone"
    schedules = [entry for entry in schedules if entry["target"] != previous_target]
    editor = {"target": None, "enabled": False}
    reloaded = schedules
    assert editor == {"target": None, "enabled": False}
    assert not any(entry["target"] == "phone" and entry["enabled"] for entry in reloaded)


def test_scheduled_work_is_tracked_cancelled_and_revalidated_before_starting_backup(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    view_model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")

    assert_contains(scheduler, "private var scheduledCheckTask: Task<Void, Never>?", "scheduled monitor checks need a retained task handle")
    assert_contains(scheduler, "private var scheduledRunTasks: [String: Task<Void, Never>]", "each delayed scheduled discovery/run needs a retained task handle")
    assert_contains(scheduler, "scheduledCheckTask?.cancel()", "stopping or replacing monitoring must cancel an outstanding check")
    assert_contains(scheduler, "scheduledRunTasks.values.forEach { $0.cancel() }", "stopping monitoring must cancel delayed per-device scheduled work")
    assert_contains(scheduler, "guard !Task.isCancelled", "scheduled work must observe cancellation after suspension")
    assert_contains(scheduler, "isScheduledRunStillValid", "scheduled work must revalidate persisted state after async discovery")
    assert_contains(view_model, "cancelBackupRequest(udid: udid, requestID: request.id)", "task cancellation must remove the exact scheduled queue request")
    assert_contains(view_model, "requestTracker.cancel(requestID", "scheduled cancellation must not bluntly cancel a manual caller sharing the same UDID")
    started_owner = view_model.split("case .started:", 1)[1].split("} onCancel:", 1)[0]
    continuation_index = started_owner.index("backupCompletionContinuations[udid] = continuation")
    task_index = started_owner.index("let task = Task")
    assert continuation_index < task_index, "the started owner must install its detachable completion before launching shared work"
    assert_contains(started_owner, "backupJobTasks[udid] = task", "the independently running shared job must remain tracked for cancellation")
    assert_not_contains(started_owner, "await runBackupJob(udid: udid)", "the started request must not remain structurally attached to a manual-backed shared job")
    detach_path = view_model.split("case .detachRequest:", 1)[1].split("case .notFound:", 1)[0]
    assert_contains(detach_path, "backupCompletionContinuations.removeValue(forKey: udid)?.resume()", "owner detachment must remove and resume its continuation exactly once")
    cancel_work = scheduler.split("private func cancelScheduledWork", 1)[1].split("private func cancelInvalidScheduledWork", 1)[0]
    invalid_work = scheduler.split("private func cancelInvalidScheduledWork", 1)[1].split("private func finishScheduledRunTask", 1)[0]
    assert_not_contains(cancel_work, "scheduledRunOwnership.removeAll()", "stop-monitoring cancellation must retain ownership until queue cancellation is terminal")
    assert_not_contains(invalid_work, "finishScheduledBackupRun", "retargeting must not release run ownership before the exact queue request is cancelled")

    run_body = scheduler.split("private func run(", 1)[1].split("private func isScheduledRunStillValid", 1)[0]
    discovery_index = run_body.index("findTargetDevice(for: runSchedule)")
    validation_index = run_body.rindex("isScheduledRunStillValid")
    backup_index = run_body.index("runScheduledBackup(")
    assert discovery_index < validation_index < backup_index, "a stale schedule must be revalidated after discovery and before it can enqueue a backup"

    # Focused race model: discovery can finish after the app suspends/returns and
    # the user disables, retargets, or stops monitoring. None may start a backup.
    def may_start_after_discovery(*, monitoring: bool, enabled: bool, stored_target: str | None, run_target: str | None, cancelled: bool) -> bool:
        return monitoring and enabled and stored_target == run_target and not cancelled

    assert not may_start_after_discovery(monitoring=False, enabled=True, stored_target="phone", run_target="phone", cancelled=True)
    assert not may_start_after_discovery(monitoring=True, enabled=False, stored_target="phone", run_target="phone", cancelled=True)
    assert not may_start_after_discovery(monitoring=True, enabled=True, stored_target="tablet", run_target="phone", cancelled=True)
    assert may_start_after_discovery(monitoring=True, enabled=True, stored_target="phone", run_target="phone", cancelled=False)


def test_due_schedule_retries_after_transient_device_discovery_miss(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    run_body = scheduler.split("private func run(", 1)[1].split("private func isScheduledRunStillValid", 1)[0]
    missing_target = run_body.split("guard let target = discovery.target else", 1)[1].split("await runScheduledBackup", 1)[0]

    assert_contains(missing_target, "Waiting to retry:", "a transient Wi-Fi miss should remain visibly pending")
    assert_not_contains(missing_target, "lastRunDate =", "a discovery miss is not a completed scheduled attempt")
    assert_not_contains(missing_target, "nextRunDate =", "a discovery miss must remain due for the next monitor tick")
    assert_not_contains(scheduler, "advanceAfterDiscoveryFailure", "automatic and Run Now discovery misses should share retry-safe semantics")


def test_schedule_completion_requires_current_persisted_schedule_and_run_ownership(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    ownership = root / "Sources/Phosphor/Services/ScheduledRunOwnership.swift"

    assert ownership.exists(), "scheduled work needs a production run-ownership type that can be behaviorally exercised"
    assert_contains(scheduler, "private var scheduledRunOwnership = ScheduledRunOwnership()", "the scheduler must track each in-flight run by a unique ownership token")
    assert_contains(scheduler, "private var scheduledRunIDs: [String: UUID] = [:]", "task tracking must retain the matching run token")
    assert_contains(scheduler, "currentScheduleForCompletion", "completion writes must explicitly revalidate the persisted schedule")
    assert_not_contains(scheduler, "latestSchedule(matching: runSchedule.targetUDID) ?? runSchedule", "no post-await path may recreate a stale schedule from its run snapshot")

    task_cleanup = scheduler.split("private func finishScheduledRunTask", 1)[1].split("private func finishScheduledBackupRun", 1)[0]
    assert_contains(task_cleanup, "guard scheduledRunIDs[identity] == runID else { return }", "stale task A must not erase task B's tracking")

    completion = scheduler.split("private func runScheduledBackup", 1)[1].split("// MARK: - Device Discovery", 1)[0]
    assert_not_contains(completion, "?? runSchedule", "completion must never recreate a cleared or retargeted schedule from the stale run snapshot")

    # Model the post-await persistence contract with controllable snapshots. A
    # cleared/disabled/retargeted schedule must be a no-op, never a recreation.
    run_snapshot = {"target": "phone", "enabled": True, "generation": 1}

    def completion_write(persisted: dict[str, object] | None) -> dict[str, object] | None:
        return persisted if persisted == run_snapshot else None

    assert completion_write(None) is None
    assert completion_write({"target": "phone", "enabled": False, "generation": 1}) is None
    assert completion_write({"target": "tablet", "enabled": True, "generation": 1}) is None
    assert completion_write(run_snapshot) == run_snapshot

    # Compile and run the actual production ownership model. In particular,
    # stale task A cannot finish task B after a clear/retarget made B current.
    probe = r'''
import Foundation

@main
struct ScheduledRunOwnershipProbe {
    static func main() {
        var ownership = ScheduledRunOwnership()
        let runA = UUID()
        let runB = UUID()

        precondition(ownership.claim(identity: "phone", runID: runA))
        precondition(ownership.owns(identity: "phone", runID: runA))
        precondition(ownership.finish(identity: "phone", runID: runA))
        precondition(ownership.claim(identity: "phone", runID: runB))
        precondition(!ownership.finish(identity: "phone", runID: runA), "stale A must not clear B")
        precondition(ownership.owns(identity: "phone", runID: runB), "B must remain tracked after stale A cleanup")
        precondition(ownership.finish(identity: "phone", runID: runB))
        precondition(!ownership.isOwned(identity: "phone"))
        print("PASS")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="phosphor-scheduled-run-ownership-") as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        binary_path = temp / "scheduled-run-ownership-probe"
        probe_path.write_text(probe)
        result = subprocess.run(
            ["swiftc", "-parse-as-library", str(ownership), str(probe_path), "-o", str(binary_path)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "PASS"


def test_global_concurrent_backup_accessibility_names_each_device_and_progress(root: Path) -> None:
    backup_list = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    activity_list = backup_list.split("private var backupActivityList", 1)[1].split("private func deviceIdentity", 1)[0]

    assert_contains(activity_list, ".accessibilityElement(children: .combine)", "each global backup status container should be one VoiceOver element")
    assert_contains(activity_list, ".accessibilityLabel(\"\\(deviceIdentity(for: activity.udid)), \\(activity.displayProgressText)\")", "global status must announce the device identity and current progress")
    assert_contains(activity_list, ".accessibilityLabel(\"Cancel backup for \\(deviceIdentity(for: activity.udid))\")", "same-name concurrent backups need device-specific cancel labels")
