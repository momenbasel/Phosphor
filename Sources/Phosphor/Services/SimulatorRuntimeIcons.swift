import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Extracts real Apple system-app icons from an installed iOS Simulator
/// runtime. Backups never contain system-app icons and most Apple apps are
/// not on the App Store, so a mounted runtime
/// (/Library/Developer/CoreSimulator/Volumes/iOS_*) is the only local source
/// of the genuine artwork. Read-only, best-effort: no Xcode -> no icons, and
/// the caller falls through to its next tier.
enum SimulatorRuntimeIcons {

    /// bundleID -> app bundle path, scanned once from the newest runtime.
    private static let bundlePaths: [String: String] = scanRuntimes()

    /// Serial lock is unnecessary: `bundlePaths` is immutable after init and
    /// NSImage decoding is local to the call.
    static func icon(bundleID: String) -> NSImage? {
        guard let appPath = bundlePaths[bundleID] else { return nil }
        // Prefer the biggest AppIcon*.png in the bundle root.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: appPath) else { return nil }
        let candidates = entries
            .filter { $0.lowercased().hasPrefix("appicon") && $0.lowercased().hasSuffix(".png") }
            .sorted() // "...60x60@2x" sorts before "...76x76@2x~ipad"; either is fine
        for name in candidates.reversed() {
            let path = (appPath as NSString).appendingPathComponent(name)
            if let image = NSImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }

    /// Find every mounted simulator runtime and index Applications/*.app by
    /// bundle id. Newest runtime wins on conflicts.
    private static func scanRuntimes() -> [String: String] {
        let volumesDir = "/Library/Developer/CoreSimulator/Volumes"
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(atPath: volumesDir) else { return [:] }

        var map: [String: String] = [:]
        // Sort so the newest OS build is scanned last and overwrites older entries.
        for volume in volumes.sorted() {
            let runtimesDir = "\(volumesDir)/\(volume)/Library/Developer/CoreSimulator/Profiles/Runtimes"
            guard let runtimes = try? fm.contentsOfDirectory(atPath: runtimesDir) else { continue }
            for runtime in runtimes where runtime.hasSuffix(".simruntime") {
                let appsDir = "\(runtimesDir)/\(runtime)/Contents/Resources/RuntimeRoot/Applications"
                guard let apps = try? fm.contentsOfDirectory(atPath: appsDir) else { continue }
                for app in apps where app.hasSuffix(".app") {
                    let appPath = "\(appsDir)/\(app)"
                    let infoPath = "\(appPath)/Info.plist"
                    guard let data = fm.contents(atPath: infoPath),
                          let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                          let bundleID = plist["CFBundleIdentifier"] as? String else { continue }
                    map[bundleID] = appPath
                }
            }
        }
        return map
    }
}
