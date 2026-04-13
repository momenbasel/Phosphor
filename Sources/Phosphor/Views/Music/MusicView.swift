import SwiftUI

/// Music and ringtone transfer - browse from backup, transfer to/from device.
struct MusicView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @StateObject private var musicManager = MusicTransferManager()
    @State private var activeTab: MusicTab = .backup
    @State private var selectedTracks: Set<String> = []

    enum MusicTab: String, CaseIterable {
        case backup = "From Backup"
        case transfer = "Transfer to Device"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            switch activeTab {
            case .backup:
                backupMusicView
            case .transfer:
                transferView
            }
        }
        .onAppear {
            if let backup = backupVM.selectedBackup {
                Task { await musicManager.loadMusicFromBackup(backupPath: backup.path) }
            }
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Music & Ringtones")
                    .font(.title2.weight(.semibold))
                Text("\(musicManager.tracks.count) tracks, \(musicManager.ringtones.count) ringtones")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Tab", selection: $activeTab) {
                ForEach(MusicTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            if !selectedTracks.isEmpty {
                Button("Extract (\(selectedTracks.count))") { extractSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
            }
        }
        .padding(20)
    }

    // MARK: - Backup Music

    private var backupMusicView: some View {
        Group {
            if musicManager.isLoading {
                LoadingOverlay(message: "Scanning music library...")
            } else if musicManager.tracks.isEmpty && musicManager.ringtones.isEmpty {
                EmptyStateView(
                    icon: "music.note.list",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Music Found",
                    subtitle: "Select a backup to browse its music library and ringtones."
                )
            } else {
                List {
                    if !musicManager.ringtones.isEmpty {
                        Section("Ringtones (\(musicManager.ringtones.count))") {
                            ForEach(musicManager.ringtones) { ringtone in
                                HStack(spacing: 10) {
                                    Image(systemName: "bell.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.purple)
                                        .frame(width: 20)
                                    Text(ringtone.displayName)
                                        .font(.system(size: 13))
                                    Spacer()
                                    Text(ringtone.size.formattedFileSize)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    if !musicManager.tracks.isEmpty {
                        Section("Music (\(musicManager.tracks.count))") {
                            ForEach(musicManager.tracks) { track in
                                HStack(spacing: 10) {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.pink)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(track.relativePath)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(track.fileExtension.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                    Text(track.size.formattedFileSize)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Transfer

    private var transferView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "arrow.up.doc")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)

            Text("Transfer Music to Device")
                .font(.title3.weight(.semibold))

            Text("Drag audio files here or click to select files to transfer to your device via AFC.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            HStack(spacing: 12) {
                Button {
                    selectAndTransfer(type: "audio")
                } label: {
                    Label("Transfer Music", systemImage: "music.note")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(deviceVM.selectedDevice == nil)

                Button {
                    selectAndTransfer(type: "ringtone")
                } label: {
                    Label("Install Ringtone", systemImage: "bell")
                }
                .buttonStyle(.bordered)
                .disabled(deviceVM.selectedDevice == nil)
            }

            if musicManager.transferProgress > 0 && musicManager.transferProgress < 1 {
                ProgressView(value: musicManager.transferProgress)
                    .frame(width: 300)
            }

            if deviceVM.selectedDevice == nil {
                Text("Connect a device to transfer files")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func extractSelected() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }

        let tracks = musicManager.tracks.filter { selectedTracks.contains($0.id) }
        Task {
            let count = await musicManager.extractTracks(tracks, from: backup.path, to: url.path)
            if count > 0 { NSWorkspace.shared.open(url) }
        }
    }

    private func selectAndTransfer(type: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true

        if type == "ringtone" {
            panel.allowedContentTypes = [.init(filenameExtension: "m4r")!]
        } else {
            panel.allowedContentTypes = [.audio]
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty,
              let udid = deviceVM.selectedDevice?.id else { return }

        let paths = panel.urls.map(\.path)

        if type == "ringtone" {
            Task {
                for path in paths {
                    let _ = await musicManager.installRingtone(path: path, udid: udid)
                }
            }
        } else {
            Task {
                let _ = await musicManager.transferToDevice(files: paths, udid: udid)
            }
        }
    }
}
