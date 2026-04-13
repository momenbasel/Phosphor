import SwiftUI

/// Device-to-device transfer (clone) view.
/// Select source and destination devices, then clone all data.
struct DeviceCloneView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @StateObject private var cloneService = DeviceCloneService()
    @State private var availableDevices: [(udid: String, name: String)] = []
    @State private var sourceUDID: String?
    @State private var destinationUDID: String?
    @State private var showConfirmation = false
    @State private var isScanning = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if cloneService.isRunning {
                cloneProgressView
            } else if cloneService.phase == .complete {
                cloneCompleteView
            } else {
                deviceSelectionView
            }
        }
        .onAppear { scanDevices() }
        .alert("Start Clone?", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clone", role: .destructive) { startClone() }
        } message: {
            let srcName = availableDevices.first(where: { $0.udid == sourceUDID })?.name ?? "Unknown"
            let dstName = availableDevices.first(where: { $0.udid == destinationUDID })?.name ?? "Unknown"
            Text("This will create a full backup of \(srcName) and restore it to \(dstName). All data on the destination device will be replaced. The destination device will restart.")
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Device Clone")
                    .font(.title2.weight(.semibold))
                Text("Transfer all data from one device to another")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                scanDevices()
            } label: {
                Label("Scan Devices", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || cloneService.isRunning)
        }
        .padding(20)
    }

    // MARK: - Device Selection

    private var deviceSelectionView: some View {
        VStack(spacing: 32) {
            Spacer()

            if availableDevices.count < 2 {
                notEnoughDevicesView
            } else {
                // Source -> Destination layout
                HStack(spacing: 40) {
                    deviceSelector(
                        title: "Source",
                        subtitle: "Copy data FROM",
                        selectedUDID: $sourceUDID,
                        excludeUDID: destinationUDID,
                        color: .blue
                    )

                    // Arrow
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.indigo)
                        Text("Clone")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.indigo)
                    }

                    deviceSelector(
                        title: "Destination",
                        subtitle: "Copy data TO",
                        selectedUDID: $destinationUDID,
                        excludeUDID: sourceUDID,
                        color: .orange
                    )
                }

                // Clone button
                Button {
                    showConfirmation = true
                } label: {
                    Label("Start Clone", systemImage: "doc.on.doc.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)
                .disabled(sourceUDID == nil || destinationUDID == nil)

                if let error = cloneService.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 40)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func deviceSelector(
        title: String,
        subtitle: String,
        selectedUDID: Binding<String?>,
        excludeUDID: String?,
        color: Color
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(availableDevices.filter({ $0.udid != excludeUDID }), id: \.udid) { device in
                    Button {
                        selectedUDID.wrappedValue = device.udid
                    } label: {
                        HStack(spacing: 10) {
                            let isSelected = selectedUDID.wrappedValue == device.udid
                            let udidPreview = String(device.udid.prefix(12)) + "..."

                            Image(systemName: "iphone")
                                .font(.system(size: 18))
                                .foregroundColor(isSelected ? .white : color)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(isSelected ? .white : .primary)
                                Text(udidPreview)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(isSelected ? .white.opacity(0.7) : .gray)
                            }

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedUDID.wrappedValue == device.udid ? color : color.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedUDID.wrappedValue == device.udid ? color : color.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 240)
        }
    }

    private var notEnoughDevicesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.and.arrow.right.and.iphone")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Connect Two Devices")
                .font(.title3.weight(.semibold))

            Text("Connect both the source and destination iOS devices via USB to clone data between them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Text("\(availableDevices.count) device(s) connected")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Progress

    private var cloneProgressView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Phase indicator
            HStack(spacing: 0) {
                phaseStep("Backup", phase: .backingUp, index: 1)
                phaseLine(active: cloneService.phase == .restoring || cloneService.phase == .complete)
                phaseStep("Restore", phase: .restoring, index: 2)
            }
            .frame(width: 300)

            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: cloneService.overallProgress)
                    .stroke(Color.indigo, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: cloneService.overallProgress)

                VStack(spacing: 2) {
                    Text("\(Int(cloneService.overallProgress * 100))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(cloneService.phase.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)

            Text(cloneService.progress)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: 400)

            Text("Do not disconnect either device")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func phaseStep(_ label: String, phase: DeviceCloneService.ClonePhase, index: Int) -> some View {
        let isActive = cloneService.phase == phase
        let isDone = (index == 1 && (cloneService.phase == .restoring || cloneService.phase == .complete)) ||
                     (index == 2 && cloneService.phase == .complete)

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green : isActive ? Color.indigo : Color.gray.opacity(0.2))
                    .frame(width: 28, height: 28)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }

    private func phaseLine(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.green : Color.gray.opacity(0.2))
            .frame(height: 2)
            .frame(maxWidth: 80)
            .padding(.bottom, 16)
    }

    // MARK: - Complete

    private var cloneCompleteView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Clone Complete")
                .font(.title2.weight(.semibold))

            Text("All data has been transferred. The destination device will restart automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Done") {
                cloneService.reset()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func scanDevices() {
        isScanning = true
        Task {
            availableDevices = await cloneService.getConnectedDevices()
            isScanning = false
        }
    }

    private func startClone() {
        guard let src = sourceUDID, let dst = destinationUDID else { return }
        Task {
            let _ = await cloneService.clone(sourceUDID: src, destinationUDID: dst)
        }
    }
}
