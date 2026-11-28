import SwiftUI

/// Profile selector dropdown / card component for backup templates.
struct BackupProfileSelectorView: View {
    let udid: String
    @Binding var configuration: DeviceBackupConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Backup Profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Menu {
                    ForEach(BackupProfileType.allCases) { profile in
                        Button {
                            configuration.profileType = profile
                            configuration.save(for: udid)
                        } label: {
                            HStack {
                                Text(profile.title)
                                if configuration.profileType == profile {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: configuration.profileType.iconName)
                            .foregroundStyle(Color.brandAccent)
                        Text(configuration.profileType.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
            }

            HStack(spacing: 8) {
                Text(configuration.profileType.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Text(configuration.profileType.estimatedTimeBadge)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.brandAccent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.brandAccent)
            }

            // Transparent breakdown pills
            let summary = configuration.profileType.contentSummary
            VStack(alignment: .leading, spacing: 6) {
                // Included items
                if !summary.included.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("Includes:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)

                        FlowLayout(spacing: 4) {
                            ForEach(summary.included, id: \.self) { item in
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                    Text(item)
                                        .font(.system(size: 10))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.green)
                            }
                        }
                    }
                }

                // Excluded items
                if !summary.excluded.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("Excludes:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .leading)

                        FlowLayout(spacing: 4) {
                            ForEach(summary.excluded, id: \.self) { item in
                                HStack(spacing: 3) {
                                    Image(systemName: "minus")
                                        .font(.system(size: 8, weight: .bold))
                                    Text(item)
                                        .font(.system(size: 10))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)

        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
