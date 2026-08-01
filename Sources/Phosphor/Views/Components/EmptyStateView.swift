import SwiftUI

/// Reusable empty state placeholder: icon in a soft gradient circle, title,
/// subtitle and an optional brand-tinted action button.
struct EmptyStateView: View {

    let icon: String
    let title: String
    let subtitle: String
    var action: (() -> Void)?
    var actionLabel: String?
    var color: Color = .brandAccent

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.18), color.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 92, height: 92)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(color)
            }
            .padding(.bottom, 2)

            Text(LocalizedStringKey(title))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(LocalizedStringKey(subtitle))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if let action, let label = actionLabel {
                Button(action: action) {
                    Text(LocalizedStringKey(label))
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loading overlay with progress indicator and status text.
struct LoadingOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.brandAccent)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

/// Info row used in device overview and diagnostics.
struct InfoRow: View {
    let label: String
    let value: String
    var icon: String?
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
            }
            Text(LocalizedStringKey(label))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }
}

/// Section header with optional borderless accent action button.
struct SectionHeader: View {
    let title: String
    var action: (() -> Void)?
    var actionIcon: String?
    var actionLabel: String?

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.headline)
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        if let icon = actionIcon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .medium))
                        }
                        if let label = actionLabel {
                            Text(LocalizedStringKey(label))
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.brandAccent)
            }
        }
    }
}

#if canImport(PreviewsMacros)
#Preview("Empty State") {
    EmptyStateView(
        icon: "iphone.slash",
        title: "No Device Connected",
        subtitle: "Connect your iPhone or iPad via USB cable to get started.",
        action: {},
        actionLabel: "Refresh"
    )
}
#endif
