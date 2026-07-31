import AppKit
import SwiftUI

// MARK: - Brand Colors

extension Color {
    /// Phosphor brand accent — vivid iMazing-style blue. Slightly brighter in dark mode
    /// so it keeps contrast against dark surfaces.
    static let brandAccent = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.07, green: 0.54, blue: 1.0, alpha: 1)
        }
        return NSColor(srgbRed: 0.02, green: 0.48, blue: 0.98, alpha: 1)
    }))

    /// Elevated card surface (white in light mode, lifted dark gray in dark mode).
    static let cardBackground = Color(nsColor: .controlBackgroundColor)

    /// Standard content/window background.
    static let contentBackground = Color(nsColor: .windowBackgroundColor)

    /// Grouped content background — sits behind elevated cards, About-This-Mac style.
    static let groupedBackground = Color(nsColor: .underPageBackgroundColor)
}

// MARK: - Connection Type Colors

extension DeviceInfo.ConnectionType {
    /// Wi-Fi is blue, USB is green, unknown is gray.
    var color: Color {
        switch self {
        case .wifi: return .blue
        case .usb: return .green
        case .unknown: return .secondary
        }
    }
}

// MARK: - Sidebar Section Icon Colors

extension SidebarSection {
    /// Signature per-section icon color, iMazing style.
    var iconColor: Color {
        switch self {
        case .devices, .readiness: return .brandAccent
        case .backups: return .blue
        case .backupBrowser: return .purple
        case .timeMachine: return .teal
        case .messages: return .green
        case .whatsapp: return Color(red: 0.12, green: 0.75, blue: 0.36) // #1EBE5D-ish
        case .photos: return .orange
        case .apps: return .indigo
        case .notes: return Color(red: 1.0, green: 0.8, blue: 0.0) // #FFCC00
        case .callLog: return .green
        case .safari: return .blue
        case .health: return Color(red: 1.0, green: 0.18, blue: 0.33) // #FF2D55
        case .music: return Color(red: 0.99, green: 0.24, blue: 0.35) // #FC3C58
        case .watch: return .gray
        case .contacts: return .blue
        case .calendar: return .red
        case .clone: return .gray
        case .files: return .cyan
        case .diagnostics: return .mint
        case .battery: return .green
        case .screenCapture: return .purple
        case .location: return .blue
        case .homeScreen: return .purple
        }
    }
}

// MARK: - Elevated Card

/// iMazing-style elevated card: card background, 14pt continuous corner radius,
/// hairline stroke and a very soft shadow. Replaces the old material card look.
struct ElevatedCard: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 14
    var showsShadow: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                Color.cardBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(showsShadow ? 0.06 : 0), radius: 8, x: 0, y: 2)
    }
}

extension View {
    /// Wraps the view in an elevated card surface (see `ElevatedCard`).
    func elevatedCard(padding: CGFloat = 16, cornerRadius: CGFloat = 14) -> some View {
        modifier(ElevatedCard(padding: padding, cornerRadius: cornerRadius))
    }
}

// MARK: - Gradient Icon Tile

/// Rounded-rect tile with a soft vertical gradient of the given color hosting a
/// colored SF Symbol. Used for the hero device glyph and quick-action tiles.
struct GradientIconTile: View {
    let systemName: String
    var color: Color = .brandAccent
    var size: CGFloat = 44
    var iconSize: CGFloat? = nil
    var cornerRadius: CGFloat? = nil

    var body: some View {
        let radius = cornerRadius ?? size * 0.27
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.25), color.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: systemName)
                .font(.system(size: iconSize ?? size * 0.5, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Status Chip / Pill Badge

/// Small capsule label with tinted background — text, optional dot or icon.
struct StatusChip: View {
    let text: String
    var color: Color = .brandAccent
    var icon: String? = nil
    var dot: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Compact pill badge — white text on a solid color capsule (e.g. USB / Wi-Fi tags).
struct PillBadge: View {
    let text: String
    var color: Color = .brandAccent

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color, in: Capsule())
    }
}

// MARK: - Gauge Ring

/// Circular progress ring with a subtle track, colored trim, rounded caps and
/// centered custom content. Used for the battery gauge.
struct GaugeRing<Content: View>: View {
    var progress: Double
    var color: Color = .brandAccent
    var lineWidth: CGFloat = 8
    @ViewBuilder var content: Content

    init(progress: Double, color: Color = .brandAccent, lineWidth: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.color = color
        self.lineWidth = lineWidth
        self.content = content()
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            content
        }
    }
}

extension GaugeRing where Content == EmptyView {
    /// Ring without centered content.
    init(progress: Double, color: Color = .brandAccent, lineWidth: CGFloat = 8) {
        self.init(progress: progress, color: color, lineWidth: lineWidth) { EmptyView() }
    }
}

#if canImport(PreviewsMacros)
#Preview("Theme Components") {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            GradientIconTile(systemName: "iphone", color: .brandAccent, size: 64)
            GradientIconTile(systemName: "message.fill", color: .green, size: 44)
            GaugeRing(progress: 0.82, color: .green, lineWidth: 7) {
                Text("82%").font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .frame(width: 64, height: 64)
        }
        HStack(spacing: 8) {
            StatusChip(text: "iOS 18.1", color: .secondary, icon: "gear")
            StatusChip(text: "Wi-Fi", color: .blue, dot: true)
            PillBadge(text: "USB", color: .green)
        }
        Text("Elevated card")
            .elevatedCard()
    }
    .padding()
    .frame(width: 480)
    .background(Color.groupedBackground)
}
#endif
