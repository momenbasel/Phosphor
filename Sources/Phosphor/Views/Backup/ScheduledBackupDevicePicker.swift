import SwiftUI

/// Shared scheduled-backup target picker used by both schedule configuration surfaces.
struct ScheduledBackupDevicePicker: View {
    @Binding var targetUDID: String?
    @Binding var targetName: String?
    let devices: [DeviceInfo]
    let wifiOnly: Bool

    private var currentTargetIsConnected: Bool {
        guard let targetUDID else { return false }
        return devices.contains(where: { $0.id == targetUDID })
    }

    private var targetBinding: Binding<String?> {
        Binding(
            get: { targetUDID },
            set: { newValue in
                targetUDID = newValue
                targetName = newValue.flatMap { selectedID in
                    devices.first(where: { $0.id == selectedID })?.name
                }
            }
        )
    }

    var body: some View {
        Picker("Device", selection: targetBinding) {
            Text("Choose a Device").tag(String?.none)
            ForEach(devices) { device in
                Text("\(device.name) — \(device.displayModelName) — ID …\(device.id.suffix(8)) (\(device.connectionType.rawValue))")
                    .tag(Optional(device.id))
            }
            if let targetUDID, !currentTargetIsConnected {
                Text("\(targetName ?? "Previously Selected Device") — ID …\(targetUDID.suffix(8)) — Not Connected")
                    .tag(Optional(targetUDID))
            }
        }

        if targetUDID == nil {
            Text(devices.count > 1
                ? "Choose which device may run on this schedule. Phosphor will not pick one automatically."
                : "Choose a device for this schedule. Legacy schedules may use the only available device, but never choose between multiple devices.")
                .font(.caption)
                .foregroundStyle(devices.count > 1 ? .orange : .secondary)
        } else if !currentTargetIsConnected {
            Text("The schedule will wait until this device is available instead of backing up a different device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if wifiOnly,
                  let targetUDID,
                  devices.first(where: { $0.id == targetUDID })?.connectionType != .wifi {
            Text("This device is currently connected by USB. The schedule will wait until it is available over Wi-Fi.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
