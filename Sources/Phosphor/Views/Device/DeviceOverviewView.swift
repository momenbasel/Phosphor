import SwiftUI

/// Main device overview - hero card, storage, battery health, info grid, quick actions.
/// iMazing-style layout with elevated cards on a grouped background.
struct DeviceOverviewView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @State private var diagnostics = DiagnosticsManager()
    @State private var battery: DiagnosticsManager.BatteryDiagnostics?
    @State private var storage: DiagnosticsManager.StorageBreakdown?
    @State private var copiedField: String?
    @State private var showFullWiFiBackupConfirm = false
    @State private var pendingBackupDevice: DeviceInfo?
    @State private var pendingIncompleteBackupIssue: BackupManager.BackupFailure?
    @State private var showIncompleteBackupTrashConfirm = false
    var onShowPreflight: ((DeviceInfo) -> Void)? = nil

    var body: some View {
        Group {
            if let device = deviceVM.selectedDevice {
                ScrollView {
                    VStack(spacing: 20) {
                        heroCard(device)
                        storageSection(device)
                        batterySection
                        infoSection(device)
                        actionsSection(device)
                    }
                    .padding(24)
                }
                .background(Color.groupedBackground)
                .task(id: device.id) {
                    backupVM.loadBackups()
                    battery = await diagnostics.getBatteryDiagnostics(udid: device.id)
                    storage = await diagnostics.getStorageBreakdown(udid: device.id)
                }
            } else {
                noDeviceView
                    .background(Color.groupedBackground)
            }
        }
        .alert("Device", isPresented: $deviceVM.showPairAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deviceVM.alertMessage)
        }
        .alert("Backup", isPresented: $backupVM.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupVM.alertMessage)
        }
        .sheet(item: $backupVM.backupIssue) { issue in
            BackupIssueSheet(
                issue: issue,
                primaryActionTitle: backupIssueActionTitle(for: issue),
                primaryAction: { handleBackupIssueAction(issue) },
                secondaryActionTitle: issue.recoveryAction == .resumeBackup ? "Delete & Start Fresh" : nil,
                secondaryAction: issue.recoveryAction == .resumeBackup ? {
                    pendingIncompleteBackupIssue = issue
                    backupVM.backupIssue = nil
                    showIncompleteBackupTrashConfirm = true
                } : nil,
                dismiss: { backupVM.backupIssue = nil }
            )
        }
        .confirmationDialog(
            "Move Incomplete Backup to Trash?",
            isPresented: $showIncompleteBackupTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash & Run Full Backup") {
                if let issue = pendingIncompleteBackupIssue {
                    Task { await backupVM.deleteIncompleteBackupAndRunFull(for: issue) }
                }
                pendingIncompleteBackupIssue = nil
            }
            Button("Cancel", role: .cancel) { pendingIncompleteBackupIssue = nil }
        } message: {
            Text("The incomplete backup folder will be moved to the Trash. The device needs to be unlocked and connected over USB for the full backup to succeed.")
        }
        .alert("Full Wi-Fi Backup?", isPresented: $showFullWiFiBackupConfirm) {
            Button("Configure & Run Full Wi-Fi Backup") {
                if let device = pendingBackupDevice {
                    onShowPreflight?(device)
                }
                pendingBackupDevice = nil
            }
            Button("Cancel", role: .cancel) { pendingBackupDevice = nil }
        } message: {
            Text("This device is connected over Wi-Fi. Full backups can be slower and more sensitive to sleep, lock, and network interruptions. Incremental Wi-Fi Backup is recommended when a complete backup already exists.")
        }
    }

    private func backupIssueActionTitle(for issue: BackupManager.BackupFailure) -> String? {
        switch issue.recoveryAction {
        case .resumeBackup: return "Resume Backup"
        case .runFullBackup: return "Run Full Backup"
        case .deleteIncompleteAndRunFull: return "Delete Incomplete Backup & Run Full"
        case .openBackupSettings: return "Open Backup Settings"
        case .retry: return "Retry"
        case .none: return nil
        }
    }

    private func handleBackupIssueAction(_ issue: BackupManager.BackupFailure) {
        switch issue.recoveryAction {
        case .resumeBackup:
            backupVM.backupIssue = nil
            Task { await backupVM.resumeBackup(for: issue) }
        case .runFullBackup:
            backupVM.backupIssue = nil
            Task { await backupVM.runFullBackup(for: issue) }
        case .deleteIncompleteAndRunFull:
            pendingIncompleteBackupIssue = issue
            backupVM.backupIssue = nil
            showIncompleteBackupTrashConfirm = true
        case .openBackupSettings:
            backupVM.backupIssue = nil
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .retry:
            backupVM.backupIssue = nil
            Task { await backupVM.retryBackup(for: issue) }
        case .none:
            backupVM.backupIssue = nil
        }
    }

    private var noDeviceView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.brandAccent.opacity(0.18), Color.brandAccent.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: deviceVM.nearbyWirelessDevices.isEmpty ? "iphone.and.arrow.forward" : "wifi")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.brandAccent)
            }

            Text(deviceVM.nearbyWirelessDevices.isEmpty ? "No Device Connected" : "Nearby, Not Backup-Ready")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(deviceVM.nearbyWirelessDevices.isEmpty
                 ? "Connect your iPhone, iPad, or iPod touch via USB to manage it with Phosphor."
                 : "Finder can see a wireless iPhone/iPad, but Phosphor's backup tools cannot open a usbmux connection to it yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if !deviceVM.nearbyWirelessDevices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finder-visible devices")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(deviceVM.nearbyWirelessDevices, id: \.id) { device in
                        HStack(spacing: 8) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(Color.brandAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 13, weight: .medium))
                                if let host = device.host {
                                    Text(host)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
                .elevatedCard(padding: 12)

                Text("Unlock the device, plug it in once, tap Trust, enable Finder Wi-Fi sync, then unplug and scan again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button {
                Task { await deviceVM.refresh() }
            } label: {
                Text("Scan for Devices")
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandAccent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero Card

    private func heroCard(_ device: DeviceInfo) -> some View {
        HStack(alignment: .center, spacing: 20) {
            GradientIconTile(
                systemName: device.sfSymbolName,
                color: .brandAccent,
                size: 88,
                iconSize: 42,
                cornerRadius: 20
            )

            VStack(alignment: .leading, spacing: 7) {
                Text(device.name)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)

                Text(device.displayModelName)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    StatusChip(text: "iOS \(device.iosVersion)", color: .secondary, icon: "gear")
                    StatusChip(
                        text: device.connectionType.rawValue,
                        color: device.connectionType.color,
                        dot: true
                    )
                    if device.isPaired {
                        StatusChip(text: "Paired", color: .green, icon: "checkmark.shield.fill")
                    } else {
                        StatusChip(text: "Not Paired", color: .orange, icon: "shield.slash.fill")
                    }
                }
            }

            Spacer(minLength: 12)

            if let level = device.batteryLevel {
                VStack(spacing: 6) {
                    GaugeRing(
                        progress: Double(level) / 100,
                        color: Color.batteryColor(level: level, charging: device.batteryCharging ?? false),
                        lineWidth: 7
                    ) {
                        VStack(spacing: 1) {
                            if device.batteryCharging == true {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            }
                            Text("\(level)%")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                    }
                    .frame(width: 84, height: 84)

                    Text("Battery")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .elevatedCard(padding: 20)
    }

    // MARK: - Storage

    @ViewBuilder
    private func storageSection(_ device: DeviceInfo) -> some View {
        if let storage {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Storage")

                StorageBar(
                    segments: [
                        ("System", storage.systemUsage, .red.opacity(0.8)),
                        ("Apps", storage.appUsage, .blue),
                        ("Photos", storage.photoUsage, .orange),
                        ("Media", storage.mediaUsage, .purple),
                        ("Other", storage.otherUsage, .gray),
                    ],
                    total: storage.totalCapacity
                )

                HStack {
                    Text("\(storage.totalCapacity.formattedFileSize) total")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(storage.availableSpace.formattedFileSize) available")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Battery Detail

    @ViewBuilder
    private var batterySection: some View {
        if let battery {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Battery Health")

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow(label: "Current Charge", value: "\(battery.currentCapacity)%")
                        InfoRow(label: "Charging", value: battery.isCharging ? "Yes" : "No",
                                valueColor: battery.isCharging ? .green : .secondary)
                        InfoRow(label: "External Power", value: battery.externalConnected ? "Connected" : "No",
                                valueColor: battery.externalConnected ? .green : .secondary)
                        if let cycles = battery.cycleCount {
                            InfoRow(label: "Cycle Count", value: "\(cycles)", icon: "arrow.triangle.2.circlepath")
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if let health = battery.healthPercent {
                            InfoRow(
                                label: "Battery Health",
                                value: String(format: "%.0f%%", health),
                                icon: "heart.fill",
                                valueColor: health > 80 ? .green : health > 60 ? .orange : .red
                            )
                        }
                        if let design = battery.designCapacity {
                            InfoRow(label: "Design Capacity", value: "\(design) mAh", icon: "battery.100")
                        }
                        if let current = battery.currentMaxCapacity {
                            InfoRow(label: "Current Max", value: "\(current) mAh", icon: "battery.75")
                        }
                        if let temp = battery.temperature {
                            InfoRow(
                                label: "Temperature",
                                value: String(format: "%.1f C", temp),
                                icon: "thermometer.medium",
                                valueColor: Color.temperatureColor(temp)
                            )
                        }
                    }
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Device Info

    private func infoSection(_ device: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Device Information",
                action: { copyAllInfo(device) },
                actionIcon: "doc.on.doc",
                actionLabel: "Copy All"
            )

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                copyableInfoRow(label: "UDID", value: device.id, icon: "number")
                copyableInfoRow(label: "Serial", value: device.serialNumber, icon: "barcode")
                copyableInfoRow(label: "Model", value: device.productType, icon: "cpu")
                copyableInfoRow(label: "Build", value: device.buildVersion, icon: "hammer")
                copyableInfoRow(label: "Wi-Fi MAC", value: device.wifiAddress, icon: "wifi")
                copyableInfoRow(label: "Bluetooth", value: device.bluetoothAddress, icon: "antenna.radiowaves.left.and.right")
                if let phone = device.phoneNumber {
                    copyableInfoRow(label: "Phone", value: phone, icon: "phone")
                }
                if let imei = device.imei {
                    copyableInfoRow(label: "IMEI", value: imei, icon: "simcard")
                }
                // Extended fields from iDescriptor
                if let arch = device.cpuArchitecture, !arch.isEmpty {
                    InfoRow(label: "CPU Architecture", value: arch, icon: "cpu")
                }
                if let baseband = device.basebandVersion, !baseband.isEmpty {
                    InfoRow(label: "Baseband", value: baseband, icon: "antenna.radiowaves.left.and.right")
                }
                if let carrier = device.carrierName, !carrier.isEmpty {
                    InfoRow(label: "Carrier", value: carrier, icon: "antenna.radiowaves.left.and.right.circle")
                }
                if let state = device.activationState {
                    InfoRow(
                        label: "Activation",
                        value: state,
                        icon: "checkmark.seal",
                        valueColor: state == "Activated" ? .green : state == "Unactivated" ? .red : .orange
                    )
                }
                if let supervised = device.isSupervised {
                    InfoRow(
                        label: "Supervised",
                        value: supervised ? "Yes" : "No",
                        icon: "lock.shield",
                        valueColor: supervised ? .blue : .secondary
                    )
                }
                if let passcode = device.hasPasscode {
                    InfoRow(
                        label: "Passcode",
                        value: passcode ? "Enabled" : "None",
                        icon: "lock",
                        valueColor: passcode ? .green : .orange
                    )
                }
            }

            // Copied feedback
            if let field = copiedField {
                Text("\(field) copied")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .cardStyle()
    }

    // MARK: - Quick Actions

    private func actionsSection(_ device: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Quick Actions")

            HStack(spacing: 12) {
                ActionButton(icon: "arrow.clockwise", label: "Restart", color: .orange) {
                    Task { let _ = await diagnostics.restartDevice(udid: device.id) }
                }
                ActionButton(icon: "moon.fill", label: "Sleep", color: .indigo) {
                    Task { let _ = await diagnostics.sleepDevice(udid: device.id) }
                }
                ActionButton(icon: "camera.fill", label: "Screenshot", color: .purple) {
                    Task { await deviceVM.takeScreenshot() }
                }
                ActionButton(
                    icon: (backupVM.isBackupActive(for: device.id) || backupVM.isLoadingBackups) ? "hourglass" : backupActionIcon(for: device),
                    label: backupVM.isBackupActive(for: device.id) ? "Backing Up..." : (backupVM.isLoadingBackups ? "Scanning Disk..." : backupActionLabel(for: device)),
                    color: hasResumableBackup(for: device) ? .orange : .brandAccent
                ) {
                    startBackup(for: device)
                }
                .disabled(backupVM.isBackupActive(for: device.id))
                .disabled(backupVM.isLoadingBackups)
                .help(backupVM.isLoadingBackups ? "Scanning backup location on disk…" : (hasResumableBackup(for: device) ? "Resume interrupted backup from saved progress" : "Start a backup for this device"))
                if !device.isPaired {
                    ActionButton(icon: "link", label: "Pair", color: .green) {
                        Task { await deviceVM.pair() }
                    }
                }
                if device.connectionType == .usb {
                    ActionButton(
                        icon: deviceVM.isEnablingWiFiSync ? "hourglass" : "wifi",
                        label: deviceVM.isEnablingWiFiSync ? "Enabling..." : "Enable Wi-Fi",
                        color: .blue
                    ) {
                        Task { await deviceVM.enableWiFiSync() }
                    }
                    .disabled(deviceVM.isEnablingWiFiSync)
                    .help("Enable Finder's Show this iPhone when on Wi-Fi option for this trusted USB device")
                }
            }

            if device.connectionType == .usb {
                Text("Enable Wi-Fi turns on Finder's \"Show this iPhone when on Wi-Fi\" option. After it succeeds, unplug the cable, keep the device unlocked, then scan again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    // MARK: - Helpers

    private func hasCompleteBackup(for device: DeviceInfo) -> Bool {
        if let existing = backupVM.backups.first(where: { !$0.isArchivedSnapshot && ($0.udid == device.id || $0.id == device.id) }) {
            return existing.healthState == .complete
        }
        return BackupManager.hasExistingBackup(for: device.id) && backupVM.backups.contains { backup in
            !backup.isArchivedSnapshot && (backup.udid == device.id || backup.id == device.id)
        }
    }

    private func hasResumableBackup(for device: DeviceInfo) -> Bool {
        backupVM.hasResumableBackup(for: device.id)
    }

    private func backupActionLabel(for device: DeviceInfo) -> String {
        if hasResumableBackup(for: device) {
            return "Resume Backup"
        }
        if device.connectionType == .wifi {
            return hasCompleteBackup(for: device) ? "Wi-Fi Backup" : "Full Wi-Fi"
        }
        return hasCompleteBackup(for: device) ? "Backup" : "Full Backup"
    }

    private func backupActionIcon(for device: DeviceInfo) -> String {
        if hasResumableBackup(for: device) {
            return "play.circle.fill"
        }
        return device.connectionType == .wifi ? "wifi" : "externaldrive.badge.plus"
    }

    private func startBackup(for device: DeviceInfo) {
        if hasResumableBackup(for: device) {
            Task {
                await backupVM.resumeBackup(
                    udid: device.id,
                    preferNetwork: device.connectionType == .wifi,
                    device: device
                )
            }
            return
        }
        let preferNetwork = device.connectionType == .wifi
        let incremental = hasCompleteBackup(for: device)
        if preferNetwork && !incremental {
            pendingBackupDevice = device
            showFullWiFiBackupConfirm = true
            return
        }
        if let onShowPreflight {
            onShowPreflight(device)
        } else {
            Task { await backupVM.createBackup(udid: device.id, incremental: incremental, preferNetwork: preferNetwork) }
        }
    }

    private func copyableInfoRow(label: String, value: String, icon: String) -> some View {
        InfoRow(label: label, value: value, icon: icon)
            .onTapGesture {
                value.copyToClipboard()
                withAnimation {
                    copiedField = label
                }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { copiedField = nil }
                }
            }
            .help("Click to copy \(label)")
    }

    private func copyAllInfo(_ device: DeviceInfo) {
        var lines: [String] = []
        lines.append("Device: \(device.name)")
        lines.append("Model: \(device.displayModelName) (\(device.productType))")
        lines.append("iOS: \(device.iosVersion) (\(device.buildVersion))")
        lines.append("UDID: \(device.id)")
        lines.append("Serial: \(device.serialNumber)")
        lines.append("Wi-Fi MAC: \(device.wifiAddress)")
        lines.append("Bluetooth: \(device.bluetoothAddress)")
        if let imei = device.imei { lines.append("IMEI: \(imei)") }
        if let phone = device.phoneNumber { lines.append("Phone: \(phone)") }
        if let arch = device.cpuArchitecture { lines.append("CPU: \(arch)") }
        if let bb = device.basebandVersion { lines.append("Baseband: \(bb)") }
        if let carrier = device.carrierName { lines.append("Carrier: \(carrier)") }
        if let state = device.activationState { lines.append("Activation: \(state)") }
        lines.joined(separator: "\n").copyToClipboard()
        withAnimation { copiedField = "All info" }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copiedField = nil }
        }
    }
}

/// Quick-action tile button: colored icon above a label on a subtle rounded tile.
struct ActionButton: View {
    let icon: String
    let label: String
    var color: Color = .brandAccent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
                    .frame(height: 22)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 78, height: 62)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
