import SwiftUI

/// Main device overview - shows device info card, storage, battery, quick actions.
/// Enhanced with connection badge, expanded info, copy-to-clipboard, activation state colors.
struct DeviceOverviewView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @State private var diagnostics = DiagnosticsManager()
    @State private var battery: DiagnosticsManager.BatteryDiagnostics?
    @State private var storage: DiagnosticsManager.StorageBreakdown?
    @State private var copiedField: String?

    var body: some View {
        Group {
            if let device = deviceVM.selectedDevice {
                ScrollView {
                    VStack(spacing: 20) {
                        deviceCard(device)
                        storageSection(device)
                        batterySection
                        infoSection(device)
                        actionsSection(device)
                    }
                    .padding(24)
                }
                .task(id: device.id) {
                    battery = await diagnostics.getBatteryDiagnostics(udid: device.id)
                    storage = await diagnostics.getStorageBreakdown(udid: device.id)
                }
            } else {
                EmptyStateView(
                    icon: "iphone.and.arrow.forward",
                    title: "No Device Connected",
                    subtitle: "Connect your iPhone, iPad, or iPod touch via USB to manage it with Phosphor.",
                    action: { Task { await deviceVM.refresh() } },
                    actionLabel: "Scan for Devices"
                )
            }
        }
    }

    // MARK: - Device Card

    private func deviceCard(_ device: DeviceInfo) -> some View {
        HStack(spacing: 20) {
            VStack {
                Image(systemName: device.sfSymbolName)
                    .font(.system(size: 64))
                    .foregroundStyle(.indigo)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 100)

            VStack(alignment: .leading, spacing: 6) {
                Text(device.name)
                    .font(.title2.weight(.semibold))

                Text(device.displayModelName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label("iOS \(device.iosVersion)", systemImage: "gear")

                    // Connection type badge
                    HStack(spacing: 3) {
                        Circle()
                            .fill(device.connectionType == .wifi ? Color.blue : Color.green)
                            .frame(width: 6, height: 6)
                        Text(device.connectionType.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }

                    if device.isPaired {
                        Label("Paired", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Paired", systemImage: "shield.slash")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let level = device.batteryLevel {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.15), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: CGFloat(level) / 100)
                            .stroke(
                                Color.batteryColor(level: level, charging: device.batteryCharging ?? false),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        VStack(spacing: 0) {
                            if device.batteryCharging == true {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                            }
                            Text("\(level)%")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                        }
                    }
                    .frame(width: 72, height: 72)

                    Text("Battery")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                ActionButton(icon: "arrow.clockwise", label: "Restart") {
                    Task { let _ = await diagnostics.restartDevice(udid: device.id) }
                }
                ActionButton(icon: "moon.fill", label: "Sleep") {
                    Task { let _ = await diagnostics.sleepDevice(udid: device.id) }
                }
                ActionButton(icon: "camera.fill", label: "Screenshot") {
                    Task { let _ = await deviceVM.takeScreenshot() }
                }
                if !device.isPaired {
                    ActionButton(icon: "link", label: "Pair") {
                        Task { await deviceVM.pair() }
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Helpers

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

struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 11))
            }
            .frame(width: 72, height: 56)
        }
        .buttonStyle(.bordered)
    }
}
