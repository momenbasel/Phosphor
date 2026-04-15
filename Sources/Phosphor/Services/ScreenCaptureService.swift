import Foundation
import AppKit

/// Captures device screen via pymobiledevice3.
/// Tries developer screenshot methods, detects tunnel requirements for iOS 17+.
@MainActor
final class ScreenCaptureService: ObservableObject {

    @Published var currentFrame: NSImage?
    @Published var isCapturing = false
    @Published var error: String?
    @Published var needsTunnel = false
    @Published var frameCount = 0

    private var captureTask: Task<Void, Never>?
    private let tempPath = NSTemporaryDirectory() + "phosphor_screen_capture.png"

    func startCapture(udid: String) {
        guard !isCapturing else { return }
        isCapturing = true
        error = nil
        needsTunnel = false
        frameCount = 0

        captureTask = Task {
            // First probe - which method works?
            let method = await detectCaptureMethod(udid: udid)
            guard method != .none, !Task.isCancelled else {
                isCapturing = false
                return
            }

            while !Task.isCancelled {
                var ok = false
                switch method {
                case .developerDvt:
                    ok = await PyMobileDevice.developerScreenshot(udid: udid, outputPath: tempPath)
                case .developerLegacy:
                    let r = await PyMobileDevice.runAsync(
                        ["developer", "screenshot", tempPath, "--udid", udid], timeout: 15
                    )
                    ok = r.succeeded
                case .none:
                    break
                }

                if Task.isCancelled { break }

                if ok, let image = NSImage(contentsOfFile: tempPath) {
                    currentFrame = image
                    frameCount += 1
                    error = nil
                }

                try? await Task.sleep(for: .milliseconds(750))
            }
            isCapturing = false
        }
    }

    private enum CaptureMethod {
        case developerDvt
        case developerLegacy
        case none
    }

    private func detectCaptureMethod(udid: String) async -> CaptureMethod {
        // Try dvt screenshot
        let dvtResult = await PyMobileDevice.runAsync(
            ["developer", "dvt", "screenshot", tempPath, "--udid", udid], timeout: 15
        )
        if dvtResult.succeeded {
            if let img = NSImage(contentsOfFile: tempPath) { currentFrame = img; frameCount = 1 }
            return .developerDvt
        }

        // Try legacy developer screenshot
        let legacyResult = await PyMobileDevice.runAsync(
            ["developer", "screenshot", tempPath, "--udid", udid], timeout: 15
        )
        if legacyResult.succeeded {
            if let img = NSImage(contentsOfFile: tempPath) { currentFrame = img; frameCount = 1 }
            return .developerLegacy
        }

        // Diagnose failure
        let stderr = (dvtResult.stderr + " " + legacyResult.stderr + " " + dvtResult.output + " " + legacyResult.output).lowercased()

        if stderr.contains("tunneld") || stderr.contains("unable to connect to tunneld") || stderr.contains("start-tunnel") {
            needsTunnel = true
            error = "iOS 17+ requires tunnel service for developer tools."
        } else if stderr.contains("developer mode") || stderr.contains("developermode") {
            error = "Enable Developer Mode on device:\nSettings > Privacy & Security > Developer Mode"
        } else if stderr.contains("pair") || stderr.contains("not paired") {
            error = "Device not paired. Pair device first."
        } else {
            // Show raw error for debugging
            let rawErr = (dvtResult.stderr + legacyResult.stderr).prefix(200)
            error = "Screenshot failed.\n\(rawErr)"
        }
        return .none
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false
    }

    func singleShot(udid: String) async -> NSImage? {
        let path = NSTemporaryDirectory() + "phosphor_single_\(Int(Date().timeIntervalSince1970)).png"
        if await PyMobileDevice.developerScreenshot(udid: udid, outputPath: path) {
            return NSImage(contentsOfFile: path)
        }
        let r = await PyMobileDevice.runAsync(["developer", "screenshot", path, "--udid", udid], timeout: 15)
        if r.succeeded { return NSImage(contentsOfFile: path) }
        return nil
    }

    func saveCurrentFrame(to path: String) -> Bool {
        guard let image = currentFrame,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Start tunneld with admin privileges via osascript.
    static func startTunnelService() {
        let pyPath = PyMobileDevice.findBinaryPath() ?? "pymobiledevice3"
        // Use osascript to get admin privileges for tunnel
        let script = """
        do shell script "\(pyPath) remote tunneld &" with administrator privileges
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    deinit {
        captureTask?.cancel()
    }
}
