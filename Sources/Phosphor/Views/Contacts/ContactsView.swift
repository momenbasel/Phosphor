import SwiftUI

/// Browse and export contacts from iOS backup.
struct ContactsView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var contacts: [ContactsExtractor.Contact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedContact: ContactsExtractor.Contact?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading contacts...")
            } else if let error = errorMessage {
                EmptyStateView(icon: "person.crop.circle", title: "Contacts Unavailable", subtitle: error)
            } else if contacts.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Contacts Found",
                    subtitle: "Select a backup to browse contacts."
                )
            } else {
                HSplitView {
                    contactList
                        .frame(minWidth: 280, idealWidth: 320)
                    contactDetail
                }
            }
        }
        .onAppear(perform: load)
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Contacts")
                    .font(.title2.weight(.semibold))
                Text("\(contacts.count) contacts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Menu("Export...") {
                Button("Export as vCard (.vcf)") { exportVCard() }
                Button("Export as CSV") { exportCSV() }
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var contactList: some View {
        List(filteredContacts, selection: $selectedContact) { contact in
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Text(contact.initials)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.indigo)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.fullName)
                        .font(.system(size: 13, weight: .medium))
                    if !contact.organization.isEmpty && !contact.firstName.isEmpty {
                        Text(contact.organization)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !contact.phoneNumbers.isEmpty {
                    Text(contact.phoneNumbers.first ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .tag(contact)
        }
        .listStyle(.inset)
    }

    private var contactDetail: some View {
        Group {
            if let contact = selectedContact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Avatar
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.indigo.opacity(0.15))
                                    .frame(width: 64, height: 64)
                                Text(contact.initials)
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.indigo)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(contact.fullName)
                                    .font(.title3.weight(.semibold))
                                if !contact.organization.isEmpty {
                                    Text(contact.organization)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Divider()

                        // Phone numbers
                        if !contact.phoneNumbers.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Phone Numbers")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(contact.phoneNumbers, id: \.self) { phone in
                                    HStack {
                                        Image(systemName: "phone.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.green)
                                        Text(phone)
                                            .font(.system(size: 14))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }

                        // Emails
                        if !contact.emails.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Email Addresses")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(contact.emails, id: \.self) { email in
                                    HStack {
                                        Image(systemName: "envelope.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.blue)
                                        Text(email)
                                            .font(.system(size: 14))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }

                        if let created = contact.createdDate {
                            Text("Created: \(created.shortString)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(20)
                }
            } else {
                EmptyStateView(
                    icon: "person.crop.circle",
                    title: "Select a Contact",
                    subtitle: "Choose a contact to view details."
                )
            }
        }
    }

    private var filteredContacts: [ContactsExtractor.Contact] {
        guard !searchText.isEmpty else { return contacts }
        let q = searchText.lowercased()
        return contacts.filter {
            $0.fullName.lowercased().contains(q) ||
            $0.organization.lowercased().contains(q) ||
            $0.phoneNumbers.contains(where: { $0.contains(q) }) ||
            $0.emails.contains(where: { $0.lowercased().contains(q) })
        }
    }

    // MARK: - Actions

    private func load() {
        guard let backup = backupVM.selectedBackup else { return }
        isLoading = true
        errorMessage = nil

        guard backup.hasManifest else {
            errorMessage = BackupInfo.incompleteBackupMessage
            isLoading = false
            return
        }

        do {
            let extractor = try ContactsExtractor(backupPath: backup.path)
            contacts = try extractor.getContacts()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func exportVCard() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "contacts.vcf"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        try? ContactsExtractor(backupPath: backup.path).exportAsVCard(contacts: contacts, to: url.path)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "contacts.csv"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        try? ContactsExtractor(backupPath: backup.path).exportAsCSV(contacts: contacts, to: url.path)
    }
}
