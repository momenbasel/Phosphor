import Foundation
import SwiftUI
import AppKit

/// Drives the Home Screen snapshot view. Loads IconState.plist from the
/// selected backup, resolves app display names/icons, and exposes the layout
/// for rendering and export.
@MainActor
final class HomeScreenViewModel: ObservableObject {

    enum LoadState {
        case idle
        case loading
        case loaded(HomeScreenLayout)
        case notFound
        case failed(String)
    }

    @Published var state: LoadState = .idle
    /// bundleID -> resolved icon (filled progressively).
    @Published private(set) var icons: [String: NSImage] = [:]
    /// bundleID -> display name from Manifest.plist.
    @Published private(set) var names: [String: String] = [:]
    /// web clip id -> its icon.png from HomeDomain/Library/WebClips.
    @Published private(set) var webClipIcons: [String: NSImage] = [:]
    /// Selected page index for the pager.
    @Published var currentPage = 0

    private var loadTask: Task<Void, Never>?
    private var loadedBackupPath: String?

    /// Load (or reload) the layout for a backup. Safe to call repeatedly —
    /// a second call for the same backup is a no-op.
    func load(for backup: BackupInfo) {
        guard loadedBackupPath != backup.path, state.isLoading == false else { return }
        loadTask?.cancel()
        loadedBackupPath = backup.path
        state = .loading
        icons = [:]

        let appInfos = PlistParser.parseApplications(backup.path)
        var nameMap: [String: String] = [:]
        var placeholders: [String: Data] = [:]
        for info in appInfos {
            if let n = info.name { nameMap[info.bundleID] = n }
            if let d = info.placeholderIconData { placeholders[info.bundleID] = d }
        }
        names = nameMap

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let manifest = try BackupManifest(backupPath: backup.path)
                let extractor = HomeScreenExtractor(manifest: manifest)
                let layout = try extractor.extract()
                if Task.isCancelled { return }
                await MainActor.run { self.state = .loaded(layout) }
                await self.resolveWebClipIcons(for: layout, extractor: extractor)
                await self.resolveIcons(for: layout, placeholders: placeholders, names: nameMap)
            } catch let error as HomeScreenExtractor.ExtractorError {
                if Task.isCancelled { return }
                let newState: HomeScreenViewModel.LoadState = {
                    switch error {
                    case .notFound: return .notFound
                    case .unreadable(let u): return .failed(u)
                    }
                }()
                await MainActor.run { self.state = newState }
            } catch {
                if Task.isCancelled { return }
                let message = error.localizedDescription
                await MainActor.run { self.state = .failed(message) }
            }
        }
    }

    func reload(for backup: BackupInfo) {
        loadedBackupPath = nil
        load(for: backup)
    }

    // MARK: - Icon resolution

    private func resolveIcons(for layout: HomeScreenLayout, placeholders: [String: Data], names: [String: String]) async {
        let bundleIDs = collectBundleIDs(from: layout)
        // Resolve icons and App Store names in parallel, publishing each as
        // it lands. Names from Manifest.plist win; otherwise the iTunes
        // lookup's trackName fills the gap (cached persistently, so this is
        // one network round per app ever).
        await withTaskGroup(of: (String, NSImage?, String?).self) { group in
            for id in bundleIDs {
                group.addTask {
                    let image = await AppIconResolver.shared.icon(
                        bundleID: id,
                        displayName: names[id],
                        placeholderData: placeholders[id]
                    )
                    var storeName: String? = nil
                    if names[id] == nil && AppleAppNames.names[id] == nil {
                        storeName = await AppIconResolver.shared.appStoreName(bundleID: id)
                    }
                    return (id, image, storeName)
                }
            }
            for await (id, image, storeName) in group {
                await MainActor.run {
                    if let image { self.icons[id] = image }
                    if let storeName, self.names[id] == nil { self.names[id] = storeName }
                }
            }
        }
    }

    private func collectBundleIDs(from layout: HomeScreenLayout) -> [String] {
        var ids = Set<String>()
        func visit(_ items: [HomeScreenLayout.Item]) {
            for item in items {
                switch item {
                case .app(let bundleID, _): ids.insert(bundleID)
                case .folder(_, let pages): pages.forEach(visit)
                case .widget(let info):
                    if let owner = info.containerBundleID { ids.insert(owner) }
                case .webClip, .unknown: break
                }
            }
        }
        layout.pages.forEach { visit($0.items) }
        visit(layout.dock)
        layout.todayWidgets.compactMap(\.containerBundleID).forEach { ids.insert($0) }
        layout.ignoredApps.forEach { ids.insert($0) }
        return ids.sorted()
    }

    /// Load web-clip icons (icon.png inside each .webclip folder). Runs off
    /// main; publishes each icon as it decodes.
    private func resolveWebClipIcons(for layout: HomeScreenLayout, extractor: HomeScreenExtractor) async {
        var clipIDs = Set<String>()
        func visit(_ items: [HomeScreenLayout.Item]) {
            for item in items {
                switch item {
                case .webClip(let id, _): clipIDs.insert(id)
                case .folder(_, let pages): pages.forEach(visit)
                default: break
                }
            }
        }
        layout.pages.forEach { visit($0.items) }
        visit(layout.dock)

        for id in clipIDs {
            guard let data = extractor.webClipIcon(id: id), let image = NSImage(data: data) else { continue }
            webClipIcons[id] = image
        }
    }
}

private extension HomeScreenViewModel.LoadState {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
