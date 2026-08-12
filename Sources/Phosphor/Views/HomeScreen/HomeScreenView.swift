import SwiftUI
import AppKit

/// Renders the iPhone home screen exactly as recorded in a backup's
/// IconState.plist: pages, app placement, folders, widgets, web clips, dock.
struct HomeScreenView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @StateObject private var vm = HomeScreenViewModel()

    /// Open folder overlay: (name, pages) of the clicked folder.
    @State private var openFolder: (name: String, pages: [[HomeScreenLayout.Item]])?

    /// Canvas size of the rendered device frame (points).
    private let frameSize = CGSize(width: 340, height: 700)
    private let columns = 4
    private let rowsPerPage = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { loadIfPossible() }
        .onChange(of: backupVM.selectedBackup?.id) { _, _ in loadIfPossible() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Home Screen")
                    .font(.title2.weight(.semibold))
                if let backup = backupVM.selectedBackup {
                    Text("\(backup.deviceName) — \(backup.dateString)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let layout = currentLayout {
                Button {
                    exportPNG(layout)
                } label: {
                    Label("Export PNG", systemImage: "photo")
                }
            }
            Button {
                if let backup = backupVM.selectedBackup { vm.reload(for: backup) }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(backupVM.selectedBackup == nil)
        }
        .padding(20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle:
            EmptyStateView(icon: "iphone", title: "No Backup Selected",
                           subtitle: "Select a backup from the Backups section to see its home screen.")
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading home screen layout…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            EmptyStateView(icon: "rectangle.on.rectangle.slash",
                           title: "No Home Screen Data",
                           subtitle: "This backup does not contain IconState.plist (HomeDomain/SpringBoard).")
        case .failed(let message):
            EmptyStateView(icon: "exclamationmark.triangle", title: "Could Not Read Layout", subtitle: message)
        case .loaded(let layout):
            loadedView(layout)
        }
    }

    private func loadedView(_ layout: HomeScreenLayout) -> some View {
        let current = layout.pages.first(where: { $0.id == vm.currentPage }) ?? layout.pages.first
        return ScrollView {
            VStack(spacing: 14) {
                if let page = current {
                    devicePage(page, dock: layout.dock, layout: layout)
                        .id(page.id)
                        .overlay {
                            if let folder = openFolder {
                                folderOverlay(folder)
                            }
                        }
                }
                if layout.pages.count > 1 {
                    pager(layout)
                }
                if !layout.todayWidgets.isEmpty || !layout.ignoredApps.isEmpty {
                    extrasPanel(layout)
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func pager(_ layout: HomeScreenLayout) -> some View {
        HStack(spacing: 14) {
            Button { vm.currentPage = max(0, vm.currentPage - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(vm.currentPage == 0)
            HStack(spacing: 6) {
                ForEach(layout.pages) { page in
                    Circle()
                        .fill(page.id == vm.currentPage ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.currentPage = page.id }
                }
            }
            Button { vm.currentPage = min(layout.pages.count - 1, vm.currentPage + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(vm.currentPage >= layout.pages.count - 1)
        }
        .buttonStyle(.borderless)
    }

    /// Today-view widgets and hidden apps, below the device frame.
    private func extrasPanel(_ layout: HomeScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !layout.todayWidgets.isEmpty {
                Text("Today View Widgets")
                    .font(.headline)
                ForEach(layout.todayWidgets) { widget in
                    HStack(spacing: 8) {
                        if let owner = widget.containerBundleID, let icon = vm.icons[owner] {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        Text(widgetDisplayName(widget))
                        Text(widget.size.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
            }
            if !layout.ignoredApps.isEmpty {
                appLibrarySection(layout.ignoredApps)
            }
        }
        .frame(width: frameSize.width + 60, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// App Library-only apps as an alphabetically grouped icon grid.
    /// Groups by first letter of display name — mirrors the way the App
    /// Library search list reads, without inventing categories the backup
    /// does not record.
    private func appLibrarySection(_ bundleIDs: [String]) -> some View {
        // (displayName, bundleID) sorted by name.
        let apps = bundleIDs
            .map { (name: appDisplayName($0, nil), id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let groups = Dictionary(grouping: apps) { app -> String in
            let first = app.name.prefix(1).uppercased()
            return first.first?.isLetter == true ? first : "#"
        }
        let keys = groups.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("App Library Only")
                .font(.headline)
                .padding(.top, 4)
            Text("\(bundleIDs.count) apps hidden from the home screen")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(groups[key] ?? [], id: \.id) { app in
                            VStack(spacing: 3) {
                                iconImage(app.id)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Text(app.name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .help(app.name)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Device frame

    private func devicePage(_ page: HomeScreenLayout.Page, dock: [HomeScreenLayout.Item], layout: HomeScreenLayout) -> some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                Text("9:41").font(.system(size: 11, weight: .semibold))
                Spacer()
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.top, 16)

            // Slot grid: absolute placement in a 4x6 board.
            slotBoard(page)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Spacer(minLength: 0)

            // Dock: evenly distributed like SpringBoard, roomier padding.
            if !dock.isEmpty {
                HStack(spacing: 0) {
                    ForEach(dock) { item in
                        slot(item, compact: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }

            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 110, height: 4)
                .padding(.bottom, 8)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .background(wallpaper)
        .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    // MARK: - Board placement

    /// Absolute slot placement mirroring SpringBoard:
    /// - Items flow left-to-right, top-to-bottom in list order.
    /// - Widgets claim their gridSize footprint (2x2/4x2/4x4).
    /// - listMetadata.fixedLocations pins specific items to slot indexes
    ///   (row*columns + col), leaving holes where nothing was placed.
    private struct PlacedItem: Identifiable {
        let item: HomeScreenLayout.Item
        let col: Int, row: Int, w: Int, h: Int
        var id: String { item.id }
    }

    private func place(_ page: HomeScreenLayout.Page) -> [PlacedItem] {
        let cols = page.gridColumns
        let rows = max(page.gridRows, rowsPerPage)
        var occupied = Array(repeating: Array(repeating: false, count: cols), count: rows * 4)
        var placed: [PlacedItem] = []

        func footprint(_ item: HomeScreenLayout.Item) -> (w: Int, h: Int) {
            if case .widget(let info) = item { return info.size.cells }
            return (1, 1)
        }
        func canPlace(_ r: Int, _ c: Int, _ w: Int, _ h: Int) -> Bool {
            guard c + w <= cols, r + h <= occupied.count else { return false }
            for dr in 0..<h { for dc in 0..<w where occupied[r + dr][c + dc] { return false } }
            return true
        }
        func mark(_ r: Int, _ c: Int, _ w: Int, _ h: Int) {
            for dr in 0..<h { for dc in 0..<w { occupied[r + dr][c + dc] = true } }
        }

        // Pass 1: pinned items reserve their slots first.
        var pinned: [String: (r: Int, c: Int)] = [:]
        for (key, slotIndex) in page.fixedSlots {
            let r = slotIndex / cols, c = slotIndex % cols
            pinned[key] = (r, c)
        }
        for item in page.items {
            if let key = item.fixedLocationKey, let (r, c) = pinned[key] {
                let (w, h) = footprint(item)
                if canPlace(r, c, w, h) {
                    mark(r, c, w, h)
                    placed.append(PlacedItem(item: item, col: c, row: r, w: w, h: h))
                }
            }
        }
        let pinnedIDs = Set(placed.map(\.id))

        // Pass 2: everything else flows into the first free footprint.
        var r = 0, c = 0
        for item in page.items where !pinnedIDs.contains(item.id) {
            let (w, h) = footprint(item)
            while !canPlace(r, c, w, h) {
                c += 1
                if c >= cols { c = 0; r += 1 }
                if r >= occupied.count { break }
            }
            guard r < occupied.count else { break }
            mark(r, c, w, h)
            placed.append(PlacedItem(item: item, col: c, row: r, w: w, h: h))
        }
        return placed
    }

    private func slotBoard(_ page: HomeScreenLayout.Page) -> some View {
        let items = place(page)
        let cell = cellSize(for: page)
        let maxRow = items.map { $0.row + $0.h }.max() ?? rowsPerPage
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(items) { placed in
                Group {
                    if case .widget(let info) = placed.item {
                        // Snap widgets to the icon grid: left/right edges align
                        // with the icons of the covered columns; bottom edge
                        // aligns with the icon bottom of the covered rows
                        // (labels hang below icons, outside the widget).
                        widgetSlot(info)
                            .frame(
                                width: widgetWidth(cols: placed.w, cell: cell),
                                height: widgetHeight(rows: placed.h, cell: cell)
                            )
                            .offset(x: iconInset(cell), y: 0)
                    } else {
                        slot(placed.item)
                            .frame(width: cell.w, alignment: .top)
                    }
                }
                .offset(
                    x: CGFloat(placed.col) * (cell.w + cellSpacing),
                    y: CGFloat(placed.row) * (cell.h + cellSpacing)
                )
            }
        }
        .frame(
            width: cell.w * CGFloat(columns) + cellSpacing * CGFloat(columns - 1),
            height: (cell.h + cellSpacing) * CGFloat(max(maxRow, rowsPerPage)) - cellSpacing,
            alignment: .topLeading
        )
    }

    private let cellSpacing: CGFloat = 10
    private let iconSize: CGFloat = 52

    /// Horizontal inset from cell edge to icon edge (icons are centered).
    private func iconInset(_ cell: (w: CGFloat, h: CGFloat)) -> CGFloat {
        (cell.w - iconSize) / 2
    }

    /// Widget width spanning `cols` columns, aligned to the icons' outer edges.
    private func widgetWidth(cols: Int, cell: (w: CGFloat, h: CGFloat)) -> CGFloat {
        CGFloat(cols) * (cell.w + cellSpacing) - cellSpacing - iconInset(cell) * 2
    }

    /// Widget height spanning `rows` rows, from icon top to last row's icon bottom.
    private func widgetHeight(rows: Int, cell: (w: CGFloat, h: CGFloat)) -> CGFloat {
        CGFloat(rows - 1) * (cell.h + cellSpacing) + iconSize + 14 // + label strip
    }

    private func cellSize(for page: HomeScreenLayout.Page) -> (w: CGFloat, h: CGFloat) {
        let boardWidth = frameSize.width - 24 // horizontal padding
        let w = (boardWidth - cellSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        return (w, w + 14) // extra height for the label under the icon
    }

    // MARK: - Slots

    @ViewBuilder
    private func slot(_ item: HomeScreenLayout.Item, compact: Bool = false) -> some View {
        switch item {
        case .app(let bundleID, let name):
            appSlot(bundleID: bundleID, name: name, compact: compact)
        case .folder(let name, let pages):
            folderSlot(name: name, pages: pages, compact: compact)
        case .widget(let info):
            widgetSlot(info)
        case .webClip(let id, let name):
            webClipSlot(id: id, name: name, compact: compact)
        case .unknown(let type):
            unknownSlot(type: type, compact: compact)
        }
    }

    private func appDisplayName(_ bundleID: String, _ resolved: String?) -> String {
        AppleAppNames.displayName(for: bundleID, fallback: resolved ?? vm.names[bundleID])
    }

    private func widgetDisplayName(_ info: HomeScreenLayout.WidgetInfo) -> String {
        // Prefer the owning app's name; fall back to the widget kind.
        if let owner = info.containerBundleID {
            let appName = appDisplayName(owner, nil)
            if let kind = info.kind, !kind.isEmpty, kind.lowercased() != "widget",
               !kind.contains(".") { // "overview" is informative; reverse-DNS is not
                return "\(appName) — \(kind)"
            }
            return appName
        }
        return info.kind ?? "Widget"
    }

    private func appSlot(bundleID: String, name: String?, compact: Bool) -> some View {
        let label = appDisplayName(bundleID, name)
        return VStack(spacing: 3) {
            iconImage(bundleID)
                .frame(width: compact ? 46 : 52, height: compact ? 46 : 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 2, y: 1)
            if !compact {
                iconLabel(label)
            }
        }
        .help(label)
    }

    private func webClipSlot(id: String, name: String?, compact: Bool) -> some View {
        let label = name ?? "Bookmark"
        return VStack(spacing: 3) {
            Group {
                if let icon = vm.webClipIcons[id] {
                    Image(nsImage: icon).resizable()
                } else {
                    ZStack {
                        Color.white.opacity(0.9)
                        Image(systemName: "safari")
                            .font(.system(size: 22))
                            .foregroundStyle(.blue)
                    }
                }
            }
            .frame(width: compact ? 46 : 52, height: compact ? 46 : 52)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 2, y: 1)
            if !compact {
                iconLabel(label)
            }
        }
        .help("\(label) (web bookmark)")
    }

    private func folderSlot(name: String, pages: [[HomeScreenLayout.Item]], compact: Bool) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                let members = pages.flatMap { $0 }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 3), count: 3), spacing: 3) {
                    ForEach(members.prefix(9)) { member in
                        folderMiniIcon(member)
                    }
                }
                .padding(6)
            }
            .frame(width: compact ? 46 : 52, height: compact ? 46 : 52)
            if !compact {
                iconLabel(name)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(duration: 0.25)) { openFolder = (name, pages) }
        }
        .help(folderTooltip(name: name, pages: pages))
    }

    /// iOS-style expanded folder: dimmed wallpaper, centered rounded panel
    /// with the folder's pages as full-size icon grids. Click outside to close.
    private func folderOverlay(_ folder: (name: String, pages: [[HomeScreenLayout.Item]])) -> some View {
        ZStack {
            // Dim + blur backdrop; click to dismiss.
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.98)
                .onTapGesture {
                    withAnimation(.spring(duration: 0.2)) { openFolder = nil }
                }
            VStack(spacing: 12) {
                Text(folder.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                ForEach(Array(folder.pages.enumerated()), id: \.offset) { _, pageItems in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                        ForEach(pageItems) { item in
                            slot(item)
                        }
                    }
                }
            }
            .padding(18)
            .frame(width: frameSize.width - 60)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .allowsHitTesting(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    @ViewBuilder
    private func folderMiniIcon(_ item: HomeScreenLayout.Item) -> some View {
        switch item {
        case .app(let id, _):
            iconImage(id)
                .frame(width: 12, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .webClip(let id, _):
            Group {
                if let icon = vm.webClipIcons[id] {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "safari").font(.system(size: 8))
                }
            }
            .frame(width: 12, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        default:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 12, height: 12)
        }
    }

    private func folderTooltip(name: String, pages: [[HomeScreenLayout.Item]]) -> String {
        let members = pages.flatMap { $0 }.map { item -> String in
            switch item {
            case .app(let id, let n): return appDisplayName(id, n)
            case .webClip(_, let n): return n ?? "Bookmark"
            default: return "?"
            }
        }
        return "\(name): \(members.joined(separator: ", "))"
    }

    private func widgetSlot(_ info: HomeScreenLayout.WidgetInfo) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
            VStack(spacing: 5) {
                if let owner = info.containerBundleID, let icon = vm.icons[owner] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(widgetDisplayName(info))
                    .font(.system(size: 10, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(info.size.rawValue) widget")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .help(widgetDisplayName(info))
    }

    private func unknownSlot(type: String, compact: Bool) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: compact ? 46 : 52, height: compact ? 46 : 52)
                .overlay(
                    Image(systemName: "questionmark")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                )
            if !compact {
                iconLabel("Unknown")
            }
        }
        .help("Unrecognized IconState entry: \(type)")
    }

    private func iconLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 74)
    }

    private func iconImage(_ bundleID: String) -> some View {
        Group {
            if let image = vm.icons[bundleID] {
                Image(nsImage: image).resizable()
            } else {
                ZStack {
                    Color(hue: Double(abs(bundleID.hashValue) % 360) / 360.0, saturation: 0.55, brightness: 0.85)
                    Text(String(appDisplayName(bundleID, nil).prefix(1).uppercased()))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    // MARK: - Wallpaper

    @ViewBuilder
    private var wallpaper: some View {
        if let data = currentLayout?.wallpaperData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(
                colors: [
                    Color(hue: 0.62, saturation: 0.55, brightness: 0.55),
                    Color(hue: 0.75, saturation: 0.60, brightness: 0.30),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var currentLayout: HomeScreenLayout? {
        if case .loaded(let layout) = vm.state { return layout }
        return nil
    }

    // MARK: - Loading

    private func loadIfPossible() {
        guard let backup = backupVM.selectedBackup else { return }
        vm.load(for: backup)
    }

    // MARK: - Export

    /// Render all pages side-by-side to a PNG via ImageRenderer.
    @MainActor
    private func exportPNG(_ layout: HomeScreenLayout) {
        let exportView = HStack(spacing: 24) {
            ForEach(layout.pages) { page in
                devicePage(page, dock: layout.dock, layout: layout)
            }
        }
        .padding(32)

        let renderer = ImageRenderer(content: exportView)
        renderer.scale = 2.0
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "HomeScreen-\(backupVM.selectedBackup?.deviceName ?? "backup").png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}
