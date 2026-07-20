import SwiftUI

/// One entry in a column: a colored size, the name, an optional proportional
/// bar behind it, and a chevron for directories.
struct RowView: View {
    let node: FileNode
    let fraction: Double      // log-scaled size relative to the column max
    let isSelected: Bool      // part of the current selection path
    let isTip: Bool           // the deepest (active) selection

    var body: some View {
        ZStack(alignment: .leading) {
            // Faint proportional bar — a quick visual cue of relative size.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.barColor.opacity(0.13))
                    .frame(width: max(0, geo.size.width * fraction))
            }
            .allowsHitTesting(false)

            // Selection highlight: blue for the active tip, faint gray otherwise.
            if isTip {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor)
            } else if isSelected {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.10))
            }

            HStack(spacing: 8) {
                Text(ByteFormat.string(node.size))
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundStyle(Color.sizeHeat(fraction: fraction, selected: isTip))
                    .frame(width: 74, alignment: .trailing)

                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isTip ? Color.white : Theme.rowText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 2)

                if node.inaccessible {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isTip ? Color.white.opacity(0.85) : Color(white: 0.45))
                        .help("No permission to read this folder")
                } else if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isTip ? Color.white.opacity(0.9) : Color(white: 0.5))
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
    }
}
