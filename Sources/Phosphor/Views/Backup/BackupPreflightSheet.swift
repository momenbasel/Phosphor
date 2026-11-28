import SwiftUI

/// Pre-flight modal sheet presented when the user initiates a backup.
/// Decouples profile selection and app exclusion dials from passive overview screens,
/// adhering to SOTA macOS progressive disclosure standards.
///
/// Implements an in-place step transition so third-party app
/// data customization does NOT spawn a secondary stacked sheet, avoiding macOS
/// AppKit window layering and z-order glitches.
struct BackupPreflightSheet: View {
    let device: DeviceInfo
    @Binding var incremental: Bool
    let preferNetwork: Bool
    @Binding var configuration: DeviceBackupConfiguration
    var onNavigateToBackups: () -> Void = {}
    var onStartBackup: () -> Void

    init(
        device: DeviceInfo,
        incremental: Binding<Bool>,
        preferNetwork: Bool,
        configuration: Binding<DeviceBackupConfiguration>,
        onNavigateToBackups: @escaping () -> Void = {},
        onStartBackup: @escaping () -> Void
    ) {
        self.device = device
        self._incremental = incremental
        self.preferNetwork = preferNetwork
        self._configuration = configuration
        self.onNavigateToBackups = onNavigateToBackups
        self.onStartBackup = onStartBackup
        self._hasExistingBackup = State(initialValue: incremental.wrappedValue)
    }

    init(
        device: DeviceInfo,
        incremental: Bool,
        preferNetwork: Bool,
        configuration: Binding<DeviceBackupConfiguration>,
        onNavigateToBackups: @escaping () -> Void = {},
        onStartBackup: @escaping () -> Void
    ) {
        self.init(
            device: device,
            incremental: .constant(incremental),
            preferNetwork: preferNetwork,
            configuration: configuration,
            onNavigateToBackups: onNavigateToBackups,
            onStartBackup: onStartBackup
        )
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("phosphor.backupDirectory") private var backupDirectory = BackupManager.defaultBackupDir

    enum PreflightStep {
        case options
        case appExclusions
    }

    @State private var currentStep: PreflightStep = .options
    @State private var hasExistingBackup: Bool
    @State private var isCheckingExistingBackup = false
    @State private var existingBackupConfiguration: DeviceBackupConfiguration?
    @State private var showHelpPopover = false

    private var destinationPath: String {
        backupDirectory
    }

    private var hasProfileMismatchWithExistingBackup: Bool {
        guard hasExistingBackup, let existing = existingBackupConfiguration else { return false }
        return !configuration.isCompatibleForIncremental(with: existing)
    }

    var body: some View {
        Group {
            switch currentStep {
            case .options:
                optionsView
            case .appExclusions:
                AppExclusionView(
                    udid: device.id,
                    configuration: $configuration,
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep = .options
                        }
                    }
                )
            }
        }
        .frame(
            width: currentStep == .appExclusions ? 680 : 520,
            height: 640
        )
        .animation(.easeInOut(duration: 0.2), value: currentStep)
        .task(id: backupDirectory) {
            let udid = device.id
            let directory = backupDirectory
            isCheckingExistingBackup = true
            let result = await Task.detached(priority: .userInitiated) {
                let exists = BackupManager.hasExistingBackup(for: udid, in: directory)
                let inferred = exists ? DeviceBackupConfiguration.inferFromExistingBackup(udid: udid, in: directory) : nil
                return (exists: exists, inferred: inferred)
            }.value
            guard !Task.isCancelled else { return }
            isCheckingExistingBackup = false
            hasExistingBackup = result.exists
            existingBackupConfiguration = result.inferred
            if let inferred = result.inferred,
               !DeviceBackupConfiguration.hasPersistedConfiguration(for: udid) {
                configuration.profileType = inferred.profileType
                configuration.excludedBundleIds = inferred.excludedBundleIds
            }
            if !result.exists && incremental {
                incremental = false
            }
        }
        .onChange(of: configuration) { _, newConfig in
            guard hasExistingBackup, let existing = existingBackupConfiguration else { return }
            if !newConfig.isCompatibleForIncremental(with: existing) && incremental {
                incremental = false
            }
        }
    }

    // MARK: - Options Step View

    private var optionsView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.brandAccent.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: preferNetwork ? "wifi" : "cable.connector")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(incremental ? "Incremental Backup" : "Start Full Backup")
                        .font(.title3.weight(.bold))
                    Text(device.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Destination Callout
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "internaldrive.fill")
                                .foregroundStyle(Color.brandAccent)
                                .font(.system(size: 15))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Backup Destination")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Text(preferNetwork ? "Wi-Fi" : "USB 3.0 / USB-C")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }

                                Text(destinationPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }

                        HStack {
                            Spacer()
                            Button("Change Destination...") {
                                let panel = NSOpenPanel()
                                panel.title = "Select Backup Destination Directory"
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    backupDirectory = url.path
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))

                    // Profile Selection
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Configure Backup Profile")
                            .font(.headline)
                        Text("Choose what data domains to stream from iOS onto disk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    BackupProfileSelectorView(
                        udid: device.id,
                        configuration: $configuration
                    )

                    // Review & Customize Profile Shortcut
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.brandAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Content & App Inclusions")
                                .font(.system(size: 12, weight: .semibold))
                            Text(configuration.profileType.appInclusionSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Review & Customize...") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentStep = .appExclusions
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))

                    // Backup Mode & Archive existing backup protection
                    if hasExistingBackup {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: incremental ? "arrow.triangle.2.circlepath" : "externaldrive.badge.plus")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.brandAccent)
                                Text("Backup Mode")
                                    .font(.system(size: 12, weight: .semibold))
                                if isCheckingExistingBackup {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.7)
                                }
                                Spacer()
                                Picker("", selection: $incremental) {
                                    Text("Full Backup").tag(false)
                                    Text("Incremental (Fast)").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 220)
                                .disabled(hasProfileMismatchWithExistingBackup)
                            }

                            Text(hasProfileMismatchWithExistingBackup
                                 ? "Profile or app exclusions differ from the existing backup on disk (\(existingBackupConfiguration?.profileType.title ?? "Previous Profile")). Full Backup is selected so the existing backup is archived cleanly without mixing profiles."
                                 : (incremental
                                    ? "Updates the existing backup with only changed files since the last snapshot."
                                    : "Transfers a complete snapshot of selected domains from the device."))
                                .font(.system(size: 11))
                                .foregroundStyle(hasProfileMismatchWithExistingBackup ? Color.brandAccent : Color.secondary)

                            Divider()

                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.green)

                                Text(incremental
                                     ? "Point-in-Time Snapshot Protected"
                                     : "Existing Backup Automatically Preserved")
                                    .font(.system(size: 11, weight: .medium))

                                Spacer()

                                Button {
                                    showHelpPopover.toggle()
                                } label: {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Learn about snapshot protection and data safety")
                            }
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    } else if isCheckingExistingBackup {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking destination for existing backups...")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Unlock reminder to prevent MBErrorDomain/208
                    HStack(spacing: 10) {
                        Image(systemName: "lock.open.iphone")
                            .font(.system(size: 15))
                            .foregroundStyle(.orange)
                        Text("Keep \(device.name) unlocked and awake, then enter your passcode on the device screen when prompted.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(24)
            }

            Divider()

            // Footer actions
            HStack {
                Button {
                    showHelpPopover.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Learn about backup profiles, app data, and snapshot safety")
                .popover(isPresented: $showHelpPopover, arrowEdge: .bottom) {
                    BackupSafetyHelpView(deviceName: device.name)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    let hasPriorCompleteBackup = hasExistingBackup
                    let isIncrementalRun = incremental && hasPriorCompleteBackup
                    let targetUDID = device.id
                    let targetDir = backupDirectory
                    configuration.save(for: targetUDID)
                    dismiss()
                    Task { @MainActor in
                        _ = await Task.detached(priority: .userInitiated) {
                            if isIncrementalRun {
                                return BackupManager.cloneBackupSnapshot(for: targetUDID, in: targetDir)
                            } else {
                                return BackupManager.archiveExistingBackup(for: targetUDID, in: targetDir)
                            }
                        }.value
                        onNavigateToBackups()
                        onStartBackup()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Start Backup")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)
                .disabled(isCheckingExistingBackup)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.groupedBackground.opacity(0.5))
        }
    }
}

/// Help guide popover detailing backup safety guarantees and storage mechanics.
struct BackupSafetyHelpView: View {
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title3)
                    .foregroundStyle(Color.brandAccent)
                Text("Backup Safety & Architecture")
                    .font(.headline)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                helpRow(
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "System Accounts & Passwords",
                    detail: "Keychain credentials, Passwords, Contacts, Messages, and System Settings are always included and cannot be excluded."
                )

                helpRow(
                    icon: "arrow.triangle.2.circlepath",
                    color: .blue,
                    title: "Point-in-Time Protection",
                    detail: "Before incremental or full backups update files, a snapshot of prior backups is preserved so photos or messages deleted on \(deviceName) are never lost."
                )

                helpRow(
                    icon: "arrow.down.app.fill",
                    color: .purple,
                    title: "App Payloads & App Store",
                    detail: "App binaries are redownloaded from the App Store on restore. Excluding an app skips its local documents and cache to save disk space."
                )
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func helpRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
