import SwiftUI

/// Sidebar sections - Devices, Data, Backups, Tools (including new iDescriptor-inspired features).
enum SidebarSection: String, CaseIterable, Identifiable {
    case devices
    case readiness
    case backups
    case backupBrowser
    case timeMachine
    case homeScreen
    case unifiedSearch
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
        case .readiness: return "Readiness"
        case .backups: return "Backups"
        case .backupBrowser: return "Backup Browser"
        case .timeMachine: return "Time Machine"
        case .homeScreen: return "Home Screen"
        case .unifiedSearch: return "Unified Search"
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
        case .readiness: return "checklist.checked"
        case .backups: return "externaldrive.fill"
        case .backupBrowser: return "folder.fill"
        case .timeMachine: return "clock.arrow.circlepath"
        case .homeScreen: return "square.grid.3x3.fill"
        case .unifiedSearch: return "magnifyingglass.circle.fill"
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
        case .devices, .readiness: return .device
        case .backups, .backupBrowser, .timeMachine, .homeScreen: return .backups
        case .unifiedSearch, .messages, .whatsapp, .photos, .apps, .notes, .callLog, .safari, .health, .music, .watch, .contacts, .calendar: return .data
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

/// iMazing-style sidebar: device entries on top, grouped sections below with
/// distinctly colored icons, and a rounded accent-tinted selection highlight.
struct SidebarView: View {

    @Binding var selection: SidebarSection?
    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @State private var hoveredSection: SidebarSection?
    @State private var hoveredDeviceID: String?

    var body: some View {
        List {
            Section("Device") {
                sidebarRow(.readiness)

                if deviceVM.devices.isEmpty {
                    noDeviceRow
                } else {
                    ForEach(deviceVM.devices) { device in
                        deviceRow(device)
                            .onAppear {
                                // Auto-select first device
                                if deviceVM.selectedDevice == nil {
                                    deviceVM.selectDevice(device)
                                }
                            }
                    }
                }
            }

            Section("Data") {
                sidebarRow(.unifiedSearch)
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
                sidebarRow(.backupBrowser)
                sidebarRow(.timeMachine)
                sidebarRow(.homeScreen)
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
    }

    // MARK: - Rows

    /// Shown when no device is connected.
    private var noDeviceRow: some View {
        sidebarButton(.devices) {
            HStack(spacing: 9) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No device connected")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Text("Connect via USB or Wi-Fi")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    /// Device entry: glyph with connection dot, name + connection pill,
    /// model/iOS subtitle, right-aligned battery percentage.
    private func deviceRow(_ device: DeviceInfo) -> some View {
        let isSelected = selection == .devices && deviceVM.selectedDevice?.id == device.id
        return sidebarButton(
            .devices,
            isVisuallySelected: isSelected,
            isVisuallyHovered: hoveredDeviceID == device.id,
            onSelect: { deviceVM.selectDevice(device) },
            onHover: { hovering in
                if hovering {
                    hoveredDeviceID = device.id
                } else if hoveredDeviceID == device.id {
                    hoveredDeviceID = nil
                }
            }
        ) {
            HStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: device.sfSymbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.brandAccent : Color.primary)
                        .frame(width: 22, alignment: .center)
                    Circle()
                        .fill(device.connectionType.color)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1))
                        .offset(x: 3, y: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.brandAccent : Color.primary)
                            .lineLimit(1)
                        PillBadge(text: device.connectionType.rawValue, color: device.connectionType.color)
                    }
                    Text("\(device.displayModelName) - iOS \(device.iosVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

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
        }
    }

    /// Standard sidebar row - colored icon in a fixed-width frame, label, rounded selection.
    private func sidebarRow(_ section: SidebarSection) -> some View {
        let isSelected = selection == section
        return sidebarButton(section) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.brandAccent : section.iconColor)
                    .frame(width: 22, alignment: .center)
                Text(LocalizedStringKey(section.label))
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.brandAccent : Color.primary)
                Spacer()
            }
        }
    }

    /// Base button for sidebar items. Uses Button instead of List selection for reliability.
    private func sidebarButton<Content: View>(
        _ section: SidebarSection,
        isVisuallySelected: Bool? = nil,
        isVisuallyHovered: Bool? = nil,
        onSelect: (() -> Void)? = nil,
        onHover: ((Bool) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = isVisuallySelected ?? (selection == section)
        let isHovered = isVisuallyHovered ?? (hoveredSection == section)
        return Button {
            selection = section
            onSelect?()
        } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.brandAccent.opacity(0.14)
                                : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if let onHover {
                onHover(hovering)
            } else {
                hoveredSection = hovering ? section : nil
            }
        }
    }
}

#if canImport(PreviewsMacros)
#Preview {
    SidebarView(selection: .constant(.devices))
        .environmentObject(DeviceViewModel())
        .environmentObject(BackupViewModel())
        .frame(width: 260)
}
#endif
