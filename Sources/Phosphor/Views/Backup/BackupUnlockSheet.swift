import SwiftUI

/// Password prompt for an encrypted backup.
///
/// iOS keeps the encrypted-backup setting at the device level, so every backup
/// for a device stays encrypted until it is turned off in Finder. Backups made
/// by other tools (Finder, iMazing, libimobiledevice, pymobiledevice3) all use
/// the same format and the same password.
struct BackupUnlockSheet: View {

    let backup: BackupInfo
    @EnvironmentObject var backupVM: BackupViewModel

    @State private var password = ""
    @State private var remember = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                GradientIconTile(systemName: "lock.fill", color: .orange, size: 40, iconSize: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock Encrypted Backup")
                        .font(.headline)
                    Text("\(backup.deviceIdentityLabel) • \(backup.relativeDate)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)

            Text("This backup is encrypted. Enter the backup password to browse it, export messages and photos, and extract app data.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .onSubmit(submit)
                .disabled(backupVM.isUnlocking)

            Toggle("Remember this password in my Keychain", isOn: $remember)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
                .padding(.top, 10)
                .disabled(backupVM.isUnlocking)

            if let error = backupVM.unlockError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Text("The password never leaves this Mac. Phosphor decrypts the backup locally and keeps the password in memory for this session only, unless you ask it to remember.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                if backupVM.isUnlocking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Deriving keys...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { backupVM.cancelUnlock() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(.brandAccent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || backupVM.isUnlocking)
            }
        }
        .padding(20)
        .frame(width: 430, height: 340)
        .onAppear { passwordFocused = true }
    }

    private func submit() {
        guard !password.isEmpty, !backupVM.isUnlocking else { return }
        Task { await backupVM.submitUnlock(password: password, remember: remember) }
    }
}
