import SwiftUI

/// Time Machine-inspired backup browser with 3D perspective animation.
/// Backups are shown as cards receding into the background, scrollable through time.
/// User can select a backup snapshot to restore from.
struct BackupTimeMachineView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @EnvironmentObject var deviceVM: DeviceViewModel
    @State private var selectedIndex: Int = 0
    @State private var isAnimating = false
    @State private var showRestoreConfirm = false
    @State private var restoreProgress: String?
    @State private var isRestoring = false
    @State private var starPositions: [StarParticle] = generateStars(count: 120)

    struct StarParticle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var size: CGFloat
        var opacity: Double
        var speed: CGFloat
    }

    var body: some View {
        ZStack {
            // Deep space background
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.08),
                    Color(red: 0.05, green: 0.03, blue: 0.15),
                    Color(red: 0.08, green: 0.04, blue: 0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Animated stars
            starField

            // Backup cards in 3D perspective
            if backupVM.backups.isEmpty {
                emptyView
            } else {
                VStack(spacing: 0) {
                    // Time Machine card stack
                    GeometryReader { geo in
                        ZStack {
                            ForEach(Array(backupVM.backups.enumerated().reversed()), id: \.offset) { index, backup in
                                backupCard(backup, at: index, in: geo.size)
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                            selectedIndex = index
                                        }
                                    }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Timeline control bar
                    timelineBar
                }
            }

            // Restore overlay
            if isRestoring, let progress = restoreProgress {
                restoreOverlay(progress)
            }
        }
    }

    // MARK: - Star Field

    private var starField: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for star in starPositions {
                    // Animate stars: slow drift + twinkle
                    let drift = (elapsed * Double(star.speed)) .truncatingRemainder(dividingBy: 1.0)
                    let y = (star.y + CGFloat(drift)).truncatingRemainder(dividingBy: 1.0)
                    let twinkle = 0.5 + 0.5 * sin(elapsed * Double(star.speed) * 100 + Double(star.x) * 50)

                    let rect = CGRect(
                        x: star.x * size.width,
                        y: y * size.height,
                        width: star.size,
                        height: star.size
                    )
                    context.opacity = star.opacity * twinkle
                    context.fill(
                        Circle().path(in: rect),
                        with: .color(.white)
                    )
                }
            }
        }
    }

    // MARK: - Backup Card

    private func backupCard(_ backup: BackupInfo, at index: Int, in containerSize: CGSize) -> some View {
        let offset = index - selectedIndex
        let depth = CGFloat(offset)

        // 3D transform parameters
        let scale = max(0.5, 1.0 - depth * 0.08)
        let yOffset = depth * 50
        let zIndex = Double(backupVM.backups.count - index)
        let cardOpacity = max(0.15, 1.0 - depth * 0.12)

        return VStack(spacing: 0) {
            // Card header
            HStack {
                Image(systemName: backup.productType.hasPrefix("iPad") ? "ipad" : "iphone")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.9))

                Text(backup.deviceName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if backup.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                Text(backup.sizeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.indigo.opacity(0.6))

            // Card body
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(backup.dateString)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("(\(backup.relativeDate))")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }

                HStack(spacing: 16) {
                    Label(backup.modelName, systemImage: "cpu")
                    Label("iOS \(backup.iosVersion)", systemImage: "gear")
                    if backup.appCount > 0 {
                        Label("\(backup.appCount) apps", systemImage: "square.grid.2x2")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))

                if offset == 0 {
                    HStack(spacing: 8) {
                        Button("Restore This Backup") {
                            showRestoreConfirm = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .controlSize(.small)

                        Button("Browse") {
                            backupVM.openBackupBrowser(backup)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.white)

                        Button("Export .phosphor") {
                            exportArchive(backup)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.white)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: min(containerSize.width * 0.75, 600))
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.12))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    offset == 0 ? Color.indigo.opacity(0.8) : Color.white.opacity(0.1),
                    lineWidth: offset == 0 ? 2 : 0.5
                )
        )
        .scaleEffect(scale)
        .offset(y: yOffset)
        .opacity(cardOpacity)
        .zIndex(zIndex)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectedIndex)
        .alert("Restore Backup?", isPresented: $showRestoreConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                performRestore(backup)
            }
        } message: {
            Text("This will restore your device to the state from \(backup.dateString). The device will restart. This cannot be undone.")
        }
    }

    // MARK: - Timeline Bar

    private var timelineBar: some View {
        VStack(spacing: 8) {
            // Timeline scrubber
            HStack(spacing: 0) {
                ForEach(Array(backupVM.backups.enumerated()), id: \.offset) { index, backup in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(index == selectedIndex ? Color.indigo : Color.white.opacity(0.3))
                            .frame(width: index == selectedIndex ? 10 : 6, height: index == selectedIndex ? 10 : 6)

                        if index == selectedIndex || backupVM.backups.count <= 6 {
                            Text(backup.lastBackupDate?.compactString ?? "")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            selectedIndex = index
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            // Navigation arrows
            HStack {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedIndex = max(0, selectedIndex - 1)
                    }
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(selectedIndex > 0 ? 0.8 : 0.2))
                }
                .disabled(selectedIndex == 0)
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 2) {
                    Text("BACKUP \(selectedIndex + 1) of \(backupVM.backups.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Use arrow keys or click to navigate")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedIndex = min(backupVM.backups.count - 1, selectedIndex + 1)
                    }
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(selectedIndex < backupVM.backups.count - 1 ? 0.8 : 0.2))
                }
                .disabled(selectedIndex >= backupVM.backups.count - 1)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.4))
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.3))

            Text("No Backups to Restore")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text("Create a backup first to enable time travel through your device history.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Restore Overlay

    private func restoreOverlay(_ progress: String) -> some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.indigo)

                Text("Restoring Backup...")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(progress)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)

                Text("Do not disconnect your device")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func performRestore(_ backup: BackupInfo) {
        guard let udid = deviceVM.selectedDevice?.id else { return }
        isRestoring = true
        restoreProgress = "Preparing restore..."

        Task {
            let success = await backupVM.backupManager.restoreBackup(
                backupPath: backup.path,
                udid: udid
            ) { [self] text in
                restoreProgress = text
            }
            isRestoring = false
            restoreProgress = nil

            if !success {
                backupVM.alertMessage = "Restore failed. Check device connection."
                backupVM.showAlert = true
            }
        }
    }

    private func exportArchive(_ backup: BackupInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let path = await BackupArchiver.createArchive(from: backup, to: url.path) { progress in
                // Could show progress in UI
            }
            if let path {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: url.path)
            }
        }
    }

    // MARK: - Stars

    private static func generateStars(count: Int) -> [StarParticle] {
        (0..<count).map { _ in
            StarParticle(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                size: CGFloat.random(in: 1...3),
                opacity: Double.random(in: 0.2...0.8),
                speed: CGFloat.random(in: 0.001...0.003)
            )
        }
    }
}

// MARK: - Date Extension for compact display

extension Date {
    var compactString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: self)
    }
}
