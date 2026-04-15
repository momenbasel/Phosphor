import SwiftUI

/// Sidebar sections - Devices, Data, Backups, Tools (including new iDescriptor-inspired features).
enum SidebarSection: String, CaseIterable, Identifiable {
    case devices
    case backups
    case backupBrowser
    case timeMachine
    case messages
    case whatsapp
    case photos
    case apps
    case notes
    case callLog
    case safari
    case health
    case music
    case watch
    case contacts
    case calendar
    case clone
    case files
    case diagnostics
    case battery
    case screenCapture
    case location

    var id: String { rawValue }

    var label: String {
        switch self {
        case .devices: return "Devices"
        case .backups: return "Backups"
        case .backupBrowser: return "Backup Browser"
        case .timeMachine: return "Time Machine"
        case .messages: return "Messages"
        case .whatsapp: return "WhatsApp"
        case .photos: return "Photos"
        case .apps: return "Apps"
        case .notes: return "Notes"
        case .callLog: return "Call Log"
        case .safari: return "Safari"
        case .health: return "Health"
        case .music: return "Music"
        case .watch: return "Apple Watch"
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .clone: return "Device Clone"
        case .files: return "File System"
        case .diagnostics: return "Diagnostics"
        case .battery: return "Battery Health"
        case .screenCapture: return "Screen Capture"
        case .location: return "Location"
        }
    }

    var icon: String {
        switch self {
        case .devices: return "iphone"
        case .backups: return "externaldrive.fill"
        case .backupBrowser: return "folder.fill"
        case .timeMachine: return "clock.arrow.circlepath"
        case .messages: return "message.fill"
        case .whatsapp: return "bubble.left.and.text.bubble.right.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .apps: return "square.grid.2x2.fill"
        case .notes: return "note.text"
        case .callLog: return "phone.arrow.up.right"
        case .safari: return "safari"
        case .health: return "heart.fill"
        case .music: return "music.note.list"
        case .watch: return "applewatch"
        case .contacts: return "person.crop.circle"
        case .calendar: return "calendar"
        case .clone: return "arrow.right.arrow.left.circle"
        case .files: return "doc.on.doc.fill"
        case .diagnostics: return "waveform.path.ecg"
        case .battery: return "battery.100percent"
        case .screenCapture: return "camera.viewfinder"
        case .location: return "location.fill"
        }
    }

    var group: SidebarGroup {
        switch self {
        case .devices: return .device
        case .backups, .backupBrowser, .timeMachine: return .backups
        case .messages, .whatsapp, .photos, .apps, .notes, .callLog, .safari, .health, .music, .watch, .contacts, .calendar: return .data
        case .clone, .files, .diagnostics, .battery, .screenCapture, .location: return .tools
        }
    }
}

enum SidebarGroup: String, CaseIterable {
    case device = "Device"
    case data = "Data"
    case backups = "Backups"
    case tools = "Tools"

    var sections: [SidebarSection] {
        SidebarSection.allCases.filter { $0.group == self }
    }
}

struct SidebarView: View {

    @Binding var selection: SidebarSection?
    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel

    var body: some View {
        List(selection: $selection) {
            // Connected devices at the top
            Section("Device") {
                if deviceVM.devices.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No device connected")
                                .font(.system(size: 13))
                            Text("Connect via USB or Wi-Fi")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    } icon: {
                        Image(systemName: "iphone.slash")
                            .foregroundStyle(.tertiary)
                    }
                    .tag(SidebarSection.devices)
                } else {
                    ForEach(deviceVM.devices) { device in
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(device.name)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(device.connectionType.rawValue)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(device.connectionType == .wifi ? Color.blue : Color.green)
                                            .clipShape(Capsule())
                                    }
                                    Text("\(device.displayModelName) - iOS \(device.iosVersion)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let level = device.batteryLevel {
                                    HStack(spacing: 2) {
                                        if device.batteryCharging == true {
                                            Image(systemName: "bolt.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.green)
                                        }
                                        Text("\(level)%")
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.batteryColor(level: level, charging: device.batteryCharging ?? false))
                                    }
                                }
                            }
                        } icon: {
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: device.sfSymbolName)
                                    .foregroundStyle(.indigo)
                                    .font(.system(size: 16))
                                Circle()
                                    .fill(device.connectionType == .wifi ? Color.blue : Color.green)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .tag(SidebarSection.devices)
                    }
                }
            }

            Section("Data") {
                sidebarRow(.messages)
                sidebarRow(.whatsapp)
                sidebarRow(.photos)
                sidebarRow(.apps)
                sidebarRow(.notes)
                sidebarRow(.callLog)
                sidebarRow(.safari)
                sidebarRow(.health)
                sidebarRow(.music)
                sidebarRow(.watch)
                sidebarRow(.contacts)
                sidebarRow(.calendar)
            }

            Section("Backups") {
                sidebarRow(.backups)
                    .badge(backupVM.backups.count)
                sidebarRow(.backupBrowser)
                sidebarRow(.timeMachine)
            }

            Section("Tools") {
                sidebarRow(.battery)
                sidebarRow(.screenCapture)
                sidebarRow(.location)
                sidebarRow(.clone)
                sidebarRow(.files)
                sidebarRow(.diagnostics)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) {
            // Auto-select first device when navigating to Devices tab
            if selection == .devices, let first = deviceVM.devices.first {
                if deviceVM.selectedDevice == nil {
                    deviceVM.selectDevice(first)
                }
            }
        }
    }

    private func sidebarRow(_ section: SidebarSection) -> some View {
        Label(section.label, systemImage: section.icon)
            .tag(section)
    }
}

#Preview {
    SidebarView(selection: .constant(.devices))
        .environmentObject(DeviceViewModel())
        .environmentObject(BackupViewModel())
        .frame(width: 260)
}
