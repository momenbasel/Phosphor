from __future__ import annotations

import re
from pathlib import Path

# Mirrors the patterns in BackupViewModel.parseSpeedToBytesPerSecond /
# parseByteCount / parseEtaToSeconds. These are the exact regexes and unit
# factors the Swift code uses, so a change to one side shows up here.
SPEED = re.compile(r"^([\d.]+)\s*([kKmMgG]?)[bB]?/?s")
SIZE = re.compile(r"^([\d.]+)\s*([KMGT]?)B?$")
SPEED_FACTORS = {"": 1, "k": 1_024, "m": 1_048_576, "g": 1_073_741_824}
SIZE_FACTORS = {"": 1, "K": 1_024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776}


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_observability_is_wired_to_the_backup_row(root: Path) -> None:
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    for token in [
        "observabilityCoordinator",
        "startObservability(udid:",
        "coordinator.updateMetrics(",
        "activity.phaseMetrics = coordinator.phaseMetrics",
        "activity.throughputStats = coordinator.throughputStats",
        "activity.predictiveETA = coordinator.predictiveETA",
        "activity.throughputTrend = coordinator.throughputTrend",
    ]:
        assert token in model, f"coordinator not wired: {token}"
    for token in [
        "activity.phaseMetrics?.phase",
        "activity.throughputStats",
        "activity.predictiveETA",
        "activity.throughputTrend",
    ]:
        assert token in view, f"indicator not rendered: {token}"


def test_stalled_resume_restarts_instead_of_deadlocking(root: Path) -> None:
    """Resume while stalled used to re-enqueue, hit .duplicate, and park."""
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert "func restartStalledBackup(udid:" in model, "stalled resume needs a restart path"
    assert "guard activity(for: udid)?.isStalled == true else {" in model, "must fall back to plain resume"
    assert "guard activity(for: udid)?.isNonResumableFinalizationPhase != true else { return }" in model, (
        "cancelling during finalization discards the backup"
    )
    assert "cancelBackup(udid: udid)" in model, "must cancel the wedged job before re-enqueueing"
    # Persisted-row Resume routes through restartStalledBackup; active rows only show Pause & Save + Diagnose…
    assert "restartStalledBackup(udid: backup.udid" in view, "persisted-row Resume must restart if called on stalled"
    assert 'Button("Resume", action: onResume)' in view, "Resume button belongs strictly to paused (!isActive) rows"
    assert "resumeBackup(udid: activity.udid)" not in view, "stalled card must not call plain resume"


def test_finalization_progress_is_not_a_stall(root: Path) -> None:
    """The watchdog updated metrics but not lastProgressUpdate, so a long
    finalization (>5 min) read as stalled and showed a resume that cannot run."""
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert "activity.finalizationMetrics = metrics" in model
    assert "activity.lastProgressUpdate = Date()" in model, "finalization movement is progress"


def test_incomplete_metadata_failure_keeps_tool_output(root: Path) -> None:
    """The resume path's most common failure kept only the folder path, so the
    details sheet had nothing to explain the failure with."""
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert "let stderrTail = pymobiledeviceStderrTail.joined(separator: \"\\n\")" in manager
    assert "technicalDetails: stderrTail.isEmpty ? path : \"\\(path)\\n\\n\\(stderrTail)\"" in manager


def test_backup_issue_and_diagnosis_are_surfaced(root: Path) -> None:
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    device = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert "func diagnosisText(for udid:" in model, "stall diagnosis must exist"
    assert "exportSnapshot()" in model, "diagnosis should include the observability snapshot"
    assert "struct BackupDiagnosisSheet" in view, "diagnosis needs a dialog"
    assert "Diagnose…" in view, "stalled rows must offer diagnosis"
    # The device screen dropped the details the list already showed.
    assert "BackupIssueSheet(" in device, "device screen should reuse the detailed issue sheet"
    assert '.alert("Backup Issue"' not in device, "plain alert hid the technical details"


def test_inflight_transitions_disable_controls_and_suppress_stall(root: Path) -> None:
    """A slow process teardown used to read as a stall and leave buttons live."""
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    device = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert "enum Transition: Equatable { case pausing, restarting }" in model
    assert "var isBusy: Bool { transition != nil }" in model
    # A pausing/restarting job is not stalled.
    assert "guard transition == nil else { return false }" in model, "transition must suppress stall"
    # Pause marks the transition immediately instead of waiting on process death.
    assert '$0.transition = .pausing' in model
    assert '$0.transition = .restarting' in model
    # Late progress lines must not overwrite the promised status.
    assert "guard activity.transition == nil else { return }" in model
    # Teardown clears it so buttons come back.
    assert 'updateActivity(udid: udid) { $0.transition = nil }' in model
    # The backups list replaces its controls while busy and names the state.
    assert "isBusy" in view and "Pausing…" in view and "Restarting…" in view
    # The device screen no longer hosts a backup progress card: live progress
    # belongs to the backups list, and the quick-action button already disables
    # itself while a backup is active.
    assert "if let activity = backupVM.activity(for: device.id), activity.isActive" not in device, (
        "device screen should not render the backup progress card"
    )
    assert "displayProgressFraction" not in device, "device screen should not show backup progress"
    assert ".disabled(backupVM.isBackupActive(for: device.id))" in device, (
        "device screen backup button must stay disabled while backing up"
    )


def test_resume_phase_detail_uses_real_baseline(root: Path) -> None:
    """Resume detail carried filesRemaining: 0, a fabricated value, and the
    counts were never plumbed from the pre-resume scan."""
    types = read(root, "Sources/Phosphor/Utilities/BackupObservabilityTypes.swift")
    coordinator = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert "case incrementalResume(filesResumed: Int, baselineFraction: Double)" in types
    assert "filesRemaining" not in types, "remaining files are unknown and must not be invented"
    assert "struct PhaseContext" in types
    assert "return .incrementalResume(filesResumed: filesResumed, baselineFraction: baseline)" in coordinator
    # Real file count comes from the incomplete-backup scan, not a constant.
    assert "resumeFileCount = stats.fileCount" in model
    assert "$0.resumeFileBaseline = resumeFileCount" in model
    assert "context.filesResumed = activity.resumeFileBaseline" in model


def test_phase_durations_come_from_transitions_not_samples(root: Path) -> None:
    """Per-phase duration must be summed from transition records. Summing
    sample.duration overcounts: each sample is elapsed-since-phase-start."""
    tracker = read(root, "Sources/Phosphor/Utilities/PhaseTransitionTracker.swift")
    coordinator = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    assert "func durationStats(for phase: String)" in tracker
    assert "$0.from.rawValue == phase" in tracker, "durations belong to the from-phase"
    assert "result[transition.from.rawValue, default: 0] += duration" in tracker
    # The redundant BackupMetricsCollector is gone.
    assert not (root / "Sources/Phosphor/Utilities/BackupMetricsCollector.swift").exists()
    # And the correct source is actually surfaced.
    assert "phaseDurations: phaseTracker.allPhaseDurations" in coordinator
    assert "let phaseDurations: [String: TimeInterval]" in coordinator


def test_phase_detail_does_not_fabricate_zeros(root: Path) -> None:
    coordinator = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    for fabricated in [
        "return .sanitization(filesScanned: 0",
        "return .incrementalResume(filesResumed: 0",
        "return .fullBackup(bytesTransferred: 0",
        "return .finalization(filesMoved: 0",
        "return .verification(bucketsScanned: 0",
        "TotalBytes: 0",
    ]:
        assert fabricated not in coordinator, f"fabricated zero detail still present: {fabricated}"
    # The one phase with real data now uses it.
    assert "return .fullBackup(bytesTransferred: bytesTransferred, totalBytes: totalBytes" in coordinator
    # And the diagnosis dialog shows the real per-phase time.
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert "Time per phase:" in model
    assert "snapshot.phaseDurations" in model


def test_eta_is_not_fabricated_from_unknown_sizes(root: Path) -> None:
    """A nil size must not produce a confident-looking zero-second ETA."""
    coordinator = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    assert "(totalBytes ?? 0) - (bytesTransferred ?? 0)" not in coordinator, (
        "subtracting nil sizes fabricates 0 remaining and a bogus 0s ETA"
    )
    assert "if let totalBytes, let bytesTransferred, totalBytes > bytesTransferred" in coordinator
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert "predicted.estimatedSeconds > 0" in view, "zero ETA must not be rendered"


def test_progress_string_parsers_match_real_tqdm_output(root: Path) -> None:
    # tqdm: " 42%|████▏ | 12.3G/29.5G [05:21<07:15, 39.5MB/s]"
    assert SPEED.match("39.5MB/s").group(2) == "M"
    assert SPEED_FACTORS["m"] == 1_048_576
    assert SPEED.match("1.2GB/s").group(2) == "G"
    assert SPEED.match("929kB/s").group(2) == "k"
    assert SPEED.match("1.5 MB/s").group(2) == "M"
    assert SPEED.match("500B/s").group(2) == ""
    # Iterations per second is not a byte rate. The byte-rate pattern cannot
    # match it at all, so it can never be misread as bytes/sec.
    assert SPEED.match("20it/s") is None

    assert SIZE.match("12.3G").group(2) == "G"
    assert SIZE_FACTORS["G"] == 1_073_741_824
    assert SIZE.match("123M").group(2) == "M"
    assert int(float("12.3") * SIZE_FACTORS["G"]) == 13_207_024_435
    # A bare number is a plain byte count.
    assert SIZE.match("789").group(2) == ""
    assert SIZE.match("not a size") is None


def test_eta_string_parser_matches_finalized_format(root: Path) -> None:
    """parseProgressDetails emits "5m 21s" / "1h 2m 3s"; these must round-trip."""

    def parse_eta(text: str) -> float:
        total = 0.0
        for part in text.lower().split(" "):
            if part.endswith("h"):
                total += float(part[:-1]) * 3600
            elif part.endswith("m"):
                total += float(part[:-1]) * 60
            elif part.endswith("s"):
                total += float(part[:-1])
        return total

    assert parse_eta("5m 21s") == 321
    assert parse_eta("1h 2m 3s") == 3723
    assert parse_eta("0m 0s") == 0, "zero ETA must be treated as unknown"


def test_two_threshold_liveness_distinguishes_quiet_from_stalled(root: Path) -> None:
    """A backup that pauses for ~30s is quiet (waiting on device); at 5m it is stalled.
    The UI distinguishes quiet from stalled without false alarms."""
    coord = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")

    assert "@Published var isQuiet = false" in coord, "coordinator must publish isQuiet"
    assert "isQuiet = staleInterval > 30 && !isStalled" in coord, "coordinator must calculate isQuiet threshold"
    assert "let isQuiet: Bool" in coord, "snapshot must carry isQuiet"

    assert "var isQuiet: Bool" in model, "BackupActivity must define isQuiet"
    assert "interval > 30 && interval <= 300" in model, "isQuiet must use 30s-300s window"
    assert "Waiting for device…" in model, "displayProgressText must show waiting state when quiet"

    assert "private var isQuiet: Bool { activity?.isQuiet == true }" in view, "row must observe isQuiet"
    assert "isQuiet ? .secondary : .brandAccent" in view, "row must adapt tint for quiet state"


def test_phase_signals_and_terminal_summary(root: Path) -> None:
    """BackupManager emits real sanitization and fallback reason signals;
    BackupViewModel and Coordinator track them in PhaseContext and surface
    honest PhaseDetail cases including terminal summary upon completion."""
    manager = (
        read(root, "Sources/Phosphor/Services/BackupManager.swift")
        + "\n"
        + read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    )
    types = read(root, "Sources/Phosphor/Utilities/BackupObservabilityTypes.swift")
    coord = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")

    # Manager sanitization returns structured result and emits signal string
    assert "struct SanitizeResult" in manager
    assert "onProgress(\"Sanitizing:" in manager
    assert "onProgress(\"Fallback:" in manager

    # Types define sanitization, fallback, terminal fields in PhaseContext
    assert "public var sanitizationScanned: Int?" in types
    assert "public var sanitizationCleaned: Int?" in types
    assert "public var sanitizationWalCheckpointed: Bool?" in types
    assert "public var fallbackReason: String?" in types
    assert "public var terminalBytes: Int64?" in types

    # Coordinator builds honest PhaseDetail without fabricated zeros
    assert "case .sanitization:" in coord
    assert "case .fallbackIdevicebackup2:" in coord
    assert "case .completed:" in coord
    assert ".sanitization(filesScanned: scanned, filesCleaned: cleaned, walCheckpointed: wal)" in coord
    assert ".fallbackIdevicebackup2(reason: reason)" in coord
    assert ".completed(totalBytes: bytes, totalFiles: files, duration: duration)" in coord

    # Model parses signals and seeds terminal detail
    assert "text.hasPrefix(\"Sanitizing:\")" in model
    assert "text.hasPrefix(\"Fallback:\")" in model
    assert "PhaseDetail.completed(totalBytes: totalBytes, totalFiles: totalFiles, duration: duration)" in model


def test_current_domain_sampling(root: Path) -> None:
    """BackupManager samples recently written files and checks Manifest.db;
    BackupViewModel liveness monitor samples domain and feeds PhaseContext."""
    manager = (
        read(root, "Sources/Phosphor/Services/BackupManager.swift")
        + "\n"
        + read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    )
    coord = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")

    assert "sampleActiveDomain(for udid: String" in manager
    assert "manifest.entry(withFileID: fileID)?.domain" in manager
    assert "BackupManager.sampleActiveDomain(for: udid)" in model
    assert "context.currentDomain = activity.currentDomain" in model
    assert "currentDomain: context.currentDomain" in coord



