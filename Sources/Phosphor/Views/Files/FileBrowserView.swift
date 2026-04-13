import SwiftUI

/// Browse the iOS device filesystem via AFC (Apple File Conduit) using ifuse mount.
struct FileBrowserView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @StateObject private var fileManager = FileTransferManager()
    @State private var selectedFile: FileTransferManager.FileEntry?
    @State private var showCopyToDevice = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if !fileManager.isMounted {
                unmountedView
            } else {
                mountedView
            }
        }
        .alert("File Browser", isPresented: .constant(fileManager.lastError != nil)) {
            Button("OK") { fileManager.lastError = nil }
        } message: {
            Text(fileManager.lastError ?? "")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("File System")
                    .font(.title2.weight(.semibold))
                if fileManager.isMounted {
                    Text("Path: \(fileManager.currentPath)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if fileManager.isMounted {
                Button {
                    Task { await fileManager.navigateUp() }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(fileManager.currentPath == "/")

                Button {
                    Task { await fileManager.browse(path: fileManager.currentPath) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button("Copy to Device...") {
                    showCopyToDevice = true
                }
                .buttonStyle(.bordered)

                Button("Unmount") {
                    Task { await fileManager.unmount() }
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
            }
        }
        .padding(20)
    }

    // MARK: - Unmounted

    private var unmountedView: some View {
        EmptyStateView(
            icon: "externaldrive.connected.to.line.below",
            title: "Device Not Mounted",
            subtitle: "Mount the device filesystem to browse and transfer files. Requires ifuse (brew install ifuse).",
            action: {
                guard let udid = deviceVM.selectedDevice?.id else { return }
                Task { let _ = await fileManager.mount(udid: udid) }
            },
            actionLabel: deviceVM.selectedDevice != nil ? "Mount Device" : nil
        )
    }

    // MARK: - Mounted

    private var mountedView: some View {
        Group {
            if fileManager.isLoading {
                LoadingOverlay(message: "Loading...")
            } else if fileManager.entries.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "Empty Directory",
                    subtitle: "This directory contains no files."
                )
            } else {
                List(fileManager.entries, selection: $selectedFile) { entry in
                    fileRow(entry)
                        .tag(entry)
                        .onTapGesture(count: 2) {
                            if entry.isDirectory {
                                Task { await fileManager.navigateInto(entry) }
                            }
                        }
                        .contextMenu {
                            if !entry.isDirectory {
                                Button("Copy to Mac...") { copyToMac(entry) }
                            }
                            if entry.isDirectory {
                                Button("Open") {
                                    Task { await fileManager.navigateInto(entry) }
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                try? fileManager.deleteFile(entry)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    private func fileRow(_ entry: FileTransferManager.FileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.sfSymbol)
                .font(.system(size: 16))
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if let date = entry.modified {
                    Text(date.shortString)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if !entry.isDirectory {
                Text(entry.sizeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func copyToMac(_ entry: FileTransferManager.FileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.prompt = "Save"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? fileManager.copyToLocal(entry: entry, destination: url.path)
    }
}
