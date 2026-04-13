import SwiftUI

/// Segmented storage usage bar, similar to macOS About This Mac storage display.
struct StorageBar: View {

    let segments: [(label: String, bytes: UInt64, color: Color)]
    let total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Bar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let fraction = total > 0 ? CGFloat(segment.bytes) / CGFloat(total) : 0
                        let width = max(fraction * geo.size.width, fraction > 0 ? 2 : 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segment.color)
                            .frame(width: width)
                    }

                    // Free space
                    let usedBytes = segments.reduce(UInt64(0)) { $0 + $1.bytes }
                    let freeBytes = total > usedBytes ? total - usedBytes : 0
                    let freeFraction = total > 0 ? CGFloat(freeBytes) / CGFloat(total) : 1
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: max(freeFraction * geo.size.width, 2))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)

            // Legend
            FlowLayout(spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 8, height: 8)
                        Text(segment.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(segment.bytes.formattedFileSize)
                            .font(.system(size: 11, weight: .medium))
                    }
                }

                let usedBytes = segments.reduce(UInt64(0)) { $0 + $1.bytes }
                let freeBytes = total > usedBytes ? total - usedBytes : 0
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text("Available")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(freeBytes.formattedFileSize)
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
    }
}

/// Simple flow layout for wrapping legend items.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

#Preview {
    StorageBar(
        segments: [
            ("Apps", 32_000_000_000, .blue),
            ("Photos", 24_000_000_000, .orange),
            ("Media", 8_000_000_000, .purple),
            ("System", 12_000_000_000, .red),
        ],
        total: 128_000_000_000
    )
    .padding()
    .frame(width: 500)
}
