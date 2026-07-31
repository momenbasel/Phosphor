import Foundation

/// Model of the iPhone home screen as captured in a backup's
/// HomeDomain/Library/SpringBoard/IconState.plist.
///
/// Schema (verified against a real iOS 17/18 backup):
/// - root: buttonBar (dock), iconLists (pages), ignored (App Library only),
///   listMetadata (per-page fixed slot pins), listUniqueIdentifiers,
///   today (Today-view widgets).
/// - page item: bundle-id string | 32-hex web-clip string | folder dict
///   (displayName + iconLists + listType=folder) | widget dict
///   (elementType=widget, gridSize, containerBundleIdentifier, widgetIdentifier).
struct HomeScreenLayout {

    /// One home-screen page (index order matches swipe order).
    struct Page: Identifiable, Hashable {
        let id: Int
        /// SpringBoard's UUID for this list; keys listMetadata.
        var uuid: String?
        var items: [Item] = []
        /// bundleID/webclip-id -> fixed slot index (row*columns + col) from
        /// listMetadata.fixedLocations. Items in this map render at their
        /// pinned slot; everything else flows.
        var fixedSlots: [String: Int] = [:]
        var gridColumns = 4
        var gridRows = 6
    }

    /// A single slot on a page, in the dock, or inside a folder.
    enum Item: Hashable, Identifiable {
        case app(bundleID: String, displayName: String?)
        case folder(name: String, pages: [[Item]])
        case widget(WidgetInfo)
        /// Home-screen Safari bookmark. `id` is the 32-hex UUID string used in
        /// iconLists; the display name comes from WebClips/<id>.webclip/Info.plist.
        case webClip(id: String, displayName: String?)
        case unknown(type: String)

        var id: String {
            switch self {
            case .app(let bundleID, _): return "app-\(bundleID)"
            case .folder(let name, _): return "folder-\(name)"
            case .widget(let info): return "widget-\(info.uniqueID)"
            case .webClip(let id, _): return "webclip-\(id)"
            case .unknown(let type): return "unknown-\(type)"
            }
        }

        /// Key used by listMetadata.fixedLocations (bundle id or clip id).
        var fixedLocationKey: String? {
            switch self {
            case .app(let bundleID, _): return bundleID
            case .webClip(let id, _): return id
            case .widget(let info): return info.containerBundleID
            case .folder, .unknown: return nil
            }
        }
    }

    enum WidgetSize: String, Hashable {
        case small      // 2x2
        case medium     // 4x2
        case large      // 4x4
        case extraLarge // iPad; tolerated

        var cells: (w: Int, h: Int) {
            switch self {
            case .small: return (2, 2)
            case .medium: return (4, 2)
            case .large, .extraLarge: return (4, 4)
            }
        }
    }

    struct WidgetInfo: Hashable, Identifiable {
        var id: String { uniqueID }
        let uniqueID: String
        /// Widget extension bundle (e.g. com.apple.weather.widget).
        let extensionBundleID: String?
        /// The app that owns the widget (e.g. com.apple.weather) — icon source.
        let containerBundleID: String?
        /// Widget kind within the extension (e.g. "overview").
        let kind: String?
        let size: WidgetSize
    }

    /// Dock ("buttonBar"). Can contain folders.
    var dock: [Item] = []
    /// Ordered home-screen pages (page 0 = first swipe).
    var pages: [Page] = []
    /// Today-view widgets (swipe right from page 0).
    var todayWidgets: [WidgetInfo] = []
    /// Apps hidden from the home screen (App Library only).
    var ignoredApps: [String] = []
    /// Whether the backup contained any IconState.plist at all.
    var sourceFound = false
    /// Decoded home-screen wallpaper image data (PNG), when resolvable.
    var wallpaperData: Data? = nil
}
