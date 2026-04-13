import SwiftUI

/// Browse and export calendar events from iOS backup.
struct CalendarView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var calendars: [CalendarExtractor.CalendarInfo] = []
    @State private var events: [CalendarExtractor.CalendarEvent] = []
    @State private var selectedCalendar: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading calendar...")
            } else if let error = errorMessage {
                EmptyStateView(icon: "calendar", title: "Calendar Unavailable", subtitle: error)
            } else if calendars.isEmpty {
                EmptyStateView(
                    icon: "calendar",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Calendars Found",
                    subtitle: "Select a backup to browse calendar events."
                )
            } else {
                HSplitView {
                    calendarList
                        .frame(minWidth: 220, idealWidth: 260)
                    eventList
                }
            }
        }
        .onAppear(perform: load)
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar")
                    .font(.title2.weight(.semibold))
                Text("\(calendars.count) calendars, \(events.count) events")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu("Export...") {
                Button("Export as ICS") { exportICS() }
                Button("Export as CSV") { exportCSV() }
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var calendarList: some View {
        List(calendars, selection: $selectedCalendar) { cal in
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.indigo)
                    .frame(width: 10, height: 10)

                Text(cal.title)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Text("\(cal.eventCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(cal.id)
        }
        .listStyle(.inset)
        .onChange(of: selectedCalendar) { _, calId in
            if let calId { loadEvents(calendarId: calId) }
        }
    }

    private var eventList: some View {
        Group {
            if events.isEmpty {
                EmptyStateView(
                    icon: "calendar.day.timeline.left",
                    title: "Select a Calendar",
                    subtitle: "Choose a calendar to view events."
                )
            } else {
                List(events) { event in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 8) {
                                Text(event.startDate.shortString)
                                if !event.isAllDay {
                                    Text(event.durationString)
                                        .foregroundStyle(.indigo)
                                } else {
                                    Text("All Day")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            if !event.location.isEmpty {
                                Label(event.location, systemImage: "mappin")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        Text(event.calendarTitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Actions

    private func load() {
        guard let backup = backupVM.selectedBackup else { return }
        guard backup.hasManifest else {
            errorMessage = BackupInfo.incompleteBackupMessage
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let extractor = try CalendarExtractor(backupPath: backup.path)
            calendars = try extractor.getCalendars()
            events = try extractor.getEvents()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadEvents(calendarId: Int) {
        guard let backup = backupVM.selectedBackup else { return }
        do {
            let extractor = try CalendarExtractor(backupPath: backup.path)
            events = try extractor.getEvents(calendarId: calendarId)
        } catch {
            events = []
        }
    }

    private func exportICS() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "calendar.ics"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        try? CalendarExtractor(backupPath: backup.path).exportAsICS(events: events, to: url.path)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "calendar-events.csv"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        try? CalendarExtractor(backupPath: backup.path).exportAsCSV(events: events, to: url.path)
    }
}
