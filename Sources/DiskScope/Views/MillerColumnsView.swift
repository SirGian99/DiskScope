import SwiftUI

/// The horizontally-scrolling cascade of columns. Each selected directory adds
/// a column to its right. Handles keyboard navigation for the whole cascade.
struct MillerColumnsView: View {
    @EnvironmentObject var coordinator: ScanCoordinator
    let root: FileNode
    @Binding var selection: [FileNode]

    /// (parent directory, depth) for each visible column.
    private var columns: [(parent: FileNode, depth: Int)] {
        var result: [(FileNode, Int)] = [(root, 0)]
        for (i, node) in selection.enumerated() {
            if node.isDirectory { result.append((node, i + 1)) } else { break }
        }
        return result.map { (parent: $0.0, depth: $0.1) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        ColumnView(parent: column.parent, depth: column.depth, selection: $selection)
                            .id(index)
                        if index < columns.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .onChange(of: columns.count) { _, count in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(count - 1, anchor: .trailing)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.rightArrow) { descend(); return .handled }
        .onKeyPress(.leftArrow) { ascend(); return .handled }
    }

    // MARK: - Keyboard navigation

    private func moveSelection(by delta: Int) {
        let depth = max(0, selection.count - 1)
        let parent = selection.isEmpty ? root : (selection.last?.parent ?? root)
        let siblings = coordinator.sortedChildren(of: parent)
        guard !siblings.isEmpty else { return }

        let currentIndex = selection.isEmpty
            ? (delta > 0 ? -1 : 0)
            : (siblings.firstIndex(where: { $0 === selection.last }) ?? 0)
        let newIndex = min(max(currentIndex + delta, 0), siblings.count - 1)
        selection = Array(selection.prefix(depth)) + [siblings[newIndex]]
    }

    private func descend() {
        guard let tip = selection.last else { moveSelection(by: 1); return }
        guard tip.isDirectory, let first = coordinator.sortedChildren(of: tip).first else { return }
        selection.append(first)
    }

    private func ascend() {
        if !selection.isEmpty { selection.removeLast() }
    }
}
