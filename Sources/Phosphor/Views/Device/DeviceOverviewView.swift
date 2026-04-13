import SwiftUI

/// Main device overview - shows device info card, storage, battery, quick actions.
/// Inspired by iMazing's device dashboard but with a cleaner macOS-native aesthetic.
struct DeviceOverviewView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @State private var diagnostics = DiagnosticsManager()
    @State private var battery: DiagnosticsManager.BatteryDiagnostics?
    @State private var storage: DiagnosticsManager.StorageBreakdown?

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
            // Device illustration
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

            // Battery gauge
            if let level = device.batteryLevel {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.15), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: CGFloat(level) / 100)
                            .stroke(
                                batteryColor(level: level, charging: device.batteryCharging ?? false),
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
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if let health = battery.healthPercent {
                            InfoRow(
                                label: "Battery Health",
                                value: String(format: "%.0f%%", health),
                                valueColor: health > 80 ? .green : health > 60 ? .orange : .red
                            )
                        }
                        if let design = battery.designCapacity {
                            InfoRow(label: "Design Capacity", value: "\(design) mAh")
                        }
                        if let current = battery.currentMaxCapacity {
                            InfoRow(label: "Current Max", value: "\(current) mAh")
                        }
                    }
                }
            }
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Device Info

    private func infoSection(_ device: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Device Information")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                InfoRow(label: "UDID", value: device.id, icon: "number")
                InfoRow(label: "Serial", value: device.serialNumber, icon: "barcode")
                InfoRow(label: "Model", value: device.productType, icon: "cpu")
                InfoRow(label: "Build", value: device.buildVersion, icon: "hammer")
                InfoRow(label: "Wi-Fi MAC", value: device.wifiAddress, icon: "wifi")
                InfoRow(label: "Bluetooth", value: device.bluetoothAddress, icon: "antenna.radiowaves.left.and.right")
                if let phone = device.phoneNumber {
                    InfoRow(label: "Phone", value: phone, icon: "phone")
                }
                if let imei = device.imei {
                    InfoRow(label: "IMEI", value: imei, icon: "simcard")
                }
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func batteryColor(level: Int, charging: Bool) -> Color {
        if charging { return .green }
        if level <= 20 { return .red }
        if level <= 40 { return .orange }
        return .green
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
