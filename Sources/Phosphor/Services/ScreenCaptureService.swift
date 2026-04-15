import Foundation
import AppKit

/// Captures device screen via pymobiledevice3 developer dvt screenshot.
/// Polls at ~1-2 FPS by writing to a temp file and reloading.
@MainActor
final class ScreenCaptureService: ObservableObject {

    @Published var currentFrame: NSImage?
    @Published var isCapturing = false
    @Published var error: String?
    @Published var frameCount = 0

    private var captureTask: Task<Void, Never>?
    private let tempPath = NSTemporaryDirectory() + "phosphor_screen_capture.png"

    func startCapture(udid: String) {
        guard !isCapturing else { return }
        isCapturing = true
        error = nil
        frameCount = 0

        captureTask = Task {
            while !Task.isCancelled {
                let ok = await PyMobileDevice.developerScreenshot(udid: udid, outputPath: tempPath)
                if Task.isCancelled { break }

                if ok, let image = NSImage(contentsOfFile: tempPath) {
                    currentFrame = image
                    frameCount += 1
                    error = nil
                } else {
                    // Check for common developer mode errors
                    let result = await PyMobileDevice.runAsync(
                        ["developer", "dvt", "screenshot", tempPath, "--udid", udid],
                        timeout: 10
                    )
                    if result.stderr.lowercased().contains("developer") {
                        error = "Developer Mode must be enabled on device. Go to Settings > Privacy & Security > Developer Mode."
                        break
                    } else if result.stderr.lowercased().contains("not paired") || result.stderr.lowercased().contains("pair") {
                        error = "Device not paired. Pair the device first."
                        break
                    } else if !result.succeeded && currentFrame == nil {
                        error = "Screenshot failed. Ensure pymobiledevice3 is installed and device is connected."
                        break
                    }
                }

                try? await Task.sleep(for: .milliseconds(750))
            }
            isCapturing = false
        }
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false
    }

    /// Take a single screenshot and return the image.
    func singleShot(udid: String) async -> NSImage? {
        let path = NSTemporaryDirectory() + "phosphor_single_shot_\(Int(Date().timeIntervalSince1970)).png"
        let ok = await PyMobileDevice.developerScreenshot(udid: udid, outputPath: path)
        guard ok else { return nil }
        return NSImage(contentsOfFile: path)
    }

    /// Save current frame to a user-chosen path.
    func saveCurrentFrame(to path: String) -> Bool {
        guard let image = currentFrame,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    deinit {
        captureTask?.cancel()
    }
}
