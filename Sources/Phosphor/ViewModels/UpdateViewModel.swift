import AppKit
import Combine

@MainActor
final class UpdateViewModel: ObservableObject {
    @Published private(set) var isChecking = false

    private let updateService: UpdateService

    init(updateService: UpdateService = UpdateService()) {
        self.updateService = updateService
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            switch try await updateService.checkForUpdates() {
            case .updateAvailable(let release):
                presentAvailableUpdate(release)
            case .upToDate(let release):
                presentUpToDate(release)
            }
        } catch {
            presentFailure(error)
        }
    }

    private func presentAvailableUpdate(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Phosphor \(release.version) Is Available"
        alert.informativeText = "You are using Phosphor \(AppVersion.current). Download the latest release, then replace the existing app in Applications."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.downloadURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.releaseNotesURL)
        default:
            break
        }
    }

    private func presentUpToDate(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Phosphor Is Up to Date"
        alert.informativeText = "You are using the latest version of Phosphor (\(release.version))."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Check for Updates"
        alert.informativeText = "Check your internet connection and try again.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
