import SwiftUI
import Charts

/// Deep battery diagnostics - health gauge, cycle count, voltage, temperature, capacity chart.
struct BatteryView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @State private var battery: DiagnosticsManager.BatteryDiagnostics?
    @State private var isLoading = true
    @State private var animatedHealth: Double = 0
    @State private var refreshTask: Task<Void, Never>?

    private let diagnostics = DiagnosticsManager()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if deviceVM.selectedDevice == nil {
                EmptyStateView(
                    icon: "battery.100percent",
                    title: "No Device Connected",
                    subtitle: "Connect a device to view battery diagnostics."
                )
            } else if isLoading && battery == nil {
                LoadingOverlay(message: "Reading battery data...")
            } else if let battery {
                ScrollView {
                    VStack(spacing: 20) {
                        healthCard(battery)
                        detailsCard(battery)
                        capacityChart(battery)
                    }
                    .padding(24)
                }
            } else {
                EmptyStateView(
                    icon: "battery.0percent",
                    title: "Battery Data Unavailable",
                    subtitle: "Could not read battery diagnostics. Ensure pymobiledevice3 is installed."
                )
            }
        }
        .task(id: deviceVM.selectedDevice?.id) {
            await loadBattery()
            startPolling()
        }
        .onDisappear {
            refreshTask?.cancel()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Battery Health")
                .font(.title2.weight(.semibold))
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Button {
                Task { await loadBattery() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding(20)
    }

    // MARK: - Health Card

    private func healthCard(_ b: DiagnosticsManager.BatteryDiagnostics) -> some View {
        HStack(spacing: 32) {
            // Animated health gauge
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: animatedHealth / 100)
                    .stroke(
                        healthColor(b),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.8), value: animatedHealth)

                VStack(spacing: 2) {
                    if b.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.green)
                    }
                    if let health = b.healthPercent {
                        Text(String(format: "%.0f%%", health))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                    } else {
                        Text("\(b.currentCapacity)%")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                    }
                    Text("Health")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)

            VStack(alignment: .leading, spacing: 10) {
                if let cycles = b.cycleCount {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(cycles)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("Charge Cycles")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    statusPill(
                        b.isCharging ? "Charging" : "On Battery",
                        icon: b.isCharging ? "bolt.fill" : "battery.50percent",
                        color: b.isCharging ? .green : .secondary
                    )
                    if b.externalConnected {
                        statusPill("Power Connected", icon: "powerplug.fill", color: .green)
                    }
                }

                if let temp = b.temperature {
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(Color.temperatureColor(temp))
                        Text(String(format: "%.1f C", temp))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Details Card

    private func detailsCard(_ b: DiagnosticsManager.BatteryDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Specifications")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let design = b.designCapacity {
                    InfoRow(label: "Design Capacity", value: "\(design) mAh", icon: "battery.100")
                }
                if let current = b.currentMaxCapacity {
                    InfoRow(label: "Current Max", value: "\(current) mAh", icon: "battery.75")
                }
                if let voltage = b.voltage {
                    InfoRow(label: "Voltage", value: String(format: "%.2f V", voltage), icon: "bolt")
                }
                if let amperage = b.amperage {
                    let sign = amperage >= 0 ? "+" : ""
                    InfoRow(label: "Amperage", value: "\(sign)\(amperage) mA", icon: "arrow.up.arrow.down")
                }
                if let watts = b.watts, watts > 0 {
                    InfoRow(label: "Charging Power", value: "\(watts) W", icon: "powerplug.fill")
                }
                if let conn = b.connectionType, !conn.isEmpty {
                    InfoRow(label: "Connection", value: conn, icon: "cable.connector")
                }
                if let serial = b.serialNumber, !serial.isEmpty {
                    InfoRow(label: "Battery Serial", value: serial, icon: "number")
                }
                InfoRow(
                    label: "Fully Charged",
                    value: b.isFullyCharged ? "Yes" : "No",
                    icon: "checkmark.circle",
                    valueColor: b.isFullyCharged ? .green : .secondary
                )
            }
        }
        .cardStyle()
    }

    // MARK: - Capacity Chart

    @ViewBuilder
    private func capacityChart(_ b: DiagnosticsManager.BatteryDiagnostics) -> some View {
        if let design = b.designCapacity, let current = b.currentMaxCapacity, design > 0 {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Capacity Comparison")

                Chart {
                    BarMark(
                        x: .value("Capacity", design),
                        y: .value("Type", "Design")
                    )
                    .foregroundStyle(.gray.opacity(0.4))
                    .annotation(position: .trailing) {
                        Text("\(design) mAh")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    BarMark(
                        x: .value("Capacity", current),
                        y: .value("Type", "Current")
                    )
                    .foregroundStyle(healthColor(b))
                    .annotation(position: .trailing) {
                        Text("\(current) mAh")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: 12))
                    }
                }
                .frame(height: 80)
            }
            .cardStyle()
        }
    }

    // MARK: - Helpers

    private func statusPill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private func healthColor(_ b: DiagnosticsManager.BatteryDiagnostics) -> Color {
        if let health = b.healthPercent {
            if health > 80 { return .green }
            if health > 60 { return .orange }
            return .red
        }
        return Color.batteryColor(level: b.currentCapacity, charging: b.isCharging)
    }

    private func loadBattery() async {
        guard let udid = deviceVM.selectedDevice?.id else { return }
        isLoading = true
        battery = await diagnostics.getBatteryDiagnostics(udid: udid)
        if let health = battery?.healthPercent {
            withAnimation(.easeOut(duration: 0.8)) {
                animatedHealth = health
            }
        } else if let cap = battery?.currentCapacity {
            withAnimation(.easeOut(duration: 0.8)) {
                animatedHealth = Double(cap)
            }
        }
        isLoading = false
    }

    private func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await loadBattery()
            }
        }
    }
}
