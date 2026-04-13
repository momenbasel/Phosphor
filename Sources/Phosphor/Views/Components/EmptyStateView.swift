import SwiftUI

/// Reusable empty state placeholder with icon, title, and subtitle.
struct EmptyStateView: View {

    let icon: String
    let title: String
    let subtitle: String
    var action: (() -> Void)?
    var actionLabel: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.quaternary)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let action, let label = actionLabel {
                Button(action: action) {
                    Text(label)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
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
                .scaleEffect(1.2)
            Text(message)
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
        HStack {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
    }
}

/// Section header with optional action button.
struct SectionHeader: View {
    let title: String
    var action: (() -> Void)?
    var actionIcon: String?
    var actionLabel: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if let action {
                Button(action: action) {
                    if let icon = actionIcon {
                        Image(systemName: icon)
                    }
                    if let label = actionLabel {
                        Text(label)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

#Preview("Empty State") {
    EmptyStateView(
        icon: "iphone.slash",
        title: "No Device Connected",
        subtitle: "Connect your iPhone or iPad via USB cable to get started.",
        action: {},
        actionLabel: "Refresh"
    )
}
