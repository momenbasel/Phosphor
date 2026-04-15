import SwiftUI

/// Live screen capture from connected device via pymobiledevice3 developer screenshot.
struct ScreenCaptureView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @StateObject private var capture = ScreenCaptureService()
    @State private var rotationDegrees: Double = 0
    @State private var isMirrored = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if deviceVM.selectedDevice == nil {
                EmptyStateView(
                    icon: "camera.viewfinder",
                    title: "No Device Connected",
                    subtitle: "Connect a device to capture its screen."
                )
            } else if capture.needsTunnel {
                tunnelRequiredView
            } else if let error = capture.error {
                errorView(error)
            } else if let frame = capture.currentFrame {
                screenView(frame)
            } else if capture.isCapturing {
                LoadingOverlay(message: "Waiting for first frame...")
            } else {
                idleView
            }
        }
        .onDisappear {
            capture.stopCapture()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Screen Capture")
                .font(.title2.weight(.semibold))

            if capture.isCapturing {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Live")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.red.opacity(0.1))
                .clipShape(Capsule())
            }

            Spacer()

            if capture.isCapturing {
                Text("\(capture.frameCount) frames")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    // MARK: - Screen Display

    private func screenView(_ frame: NSImage) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(rotationDegrees))
                    .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                    .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                    .frame(width: geo.size.width, height: geo.size.height)
            }

            Divider()

            HStack(spacing: 16) {
                Button {
                    capture.stopCapture()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Divider().frame(height: 20)

                Button { withAnimation { rotationDegrees -= 90 } } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Rotate CCW")

                Button { withAnimation { rotationDegrees += 90 } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rotate CW")

                Button { withAnimation { isMirrored.toggle() } } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Mirror")

                Divider().frame(height: 20)

                Button { saveScreenshot() } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    // MARK: - Tunnel Required (iOS 17+)

    private var tunnelRequiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Tunnel Service Required")
                .font(.title3.weight(.semibold))

            Text("iOS 17+ requires a tunnel service for developer tools like\nscreen capture and location spoofing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 8) {
                Text("Option 1: Click below (requires admin password)")
                    .font(.system(size: 12, weight: .medium))
                Button {
                    ScreenCaptureService.startTunnelService()
                    // Wait a bit for tunnel to start, then retry
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        capture.needsTunnel = false
                        capture.error = nil
                        if let udid = deviceVM.selectedDevice?.id {
                            capture.startCapture(udid: udid)
                        }
                    }
                } label: {
                    Label("Start Tunnel Service", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Divider().padding(.vertical, 4)

                Text("Option 2: Run manually in Terminal")
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    Text("sudo pymobiledevice3 remote tunneld")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        "sudo pymobiledevice3 remote tunneld".copyToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color(.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding()
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                capture.needsTunnel = false
                capture.error = nil
                if let udid = deviceVM.selectedDevice?.id {
                    capture.startCapture(udid: udid)
                }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)

            Text("Screen Capture")
                .font(.title3.weight(.semibold))

            Text("Capture your device screen in real-time.\nRequires Developer Mode and tunnel service on iOS 17+.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                guard let udid = deviceVM.selectedDevice?.id else { return }
                capture.startCapture(udid: udid)
            } label: {
                Label("Start Capture", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Capture Failed")
                .font(.title3.weight(.semibold))

            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                capture.error = nil
                guard let udid = deviceVM.selectedDevice?.id else { return }
                capture.startCapture(udid: udid)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveScreenshot() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "phosphor-capture-\(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let _ = capture.saveCurrentFrame(to: url.path)
    }
}
