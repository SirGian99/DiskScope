import SwiftUI

/// A single column showing the (size-sorted) children of one directory.
struct ColumnView: View {
    @EnvironmentObject var coordinator: ScanCoordinator
    let parent: FileNode
    let depth: Int
    @Binding var selection: [FileNode]

    var body: some View {
        let nodes = coordinator.sortedChildren(of: parent)
        let maxSize = nodes.first?.size ?? 0

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(nodes) { node in
                        RowView(
                            node: node,
                            fraction: fraction(of: node, max: maxSize),
                            isSelected: depth < selection.count && selection[depth] === node,
                            isTip: selection.last === node
                        )
                        .id(node.id)
                        .contentShape(Rectangle())
                        .onTapGesture { select(node) }
                        .contextMenu {
                            Button("Copy Path") { FileActions.copyPath(node.url) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selection) { _, _ in
                guard depth < selection.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selection[depth].id, anchor: .center)
                }
            }
            .overlay(alignment: .center) {
                if nodes.isEmpty {
                    Text(parent.inaccessible ? "No access" : (parent.scanned ? "Empty" : "Scanning…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 250)
        .background(Theme.columnBackground)
    }

    private func fraction(of node: FileNode, max: Int64) -> Double {
        guard max > 0, node.size > 0 else { return 0 }
        return log(Double(node.size) + 1) / log(Double(max) + 1)
    }

    private func select(_ node: FileNode) {
        selection = Array(selection.prefix(depth)) + [node]
    }
}
