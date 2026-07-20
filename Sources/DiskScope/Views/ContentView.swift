import SwiftUI

struct ContentView: View {
    @EnvironmentObject var coordinator: ScanCoordinator
    @State private var selection: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            ScanBar(selection: $selection)
            Divider()

            Group {
                if let root = coordinator.root {
                    MillerColumnsView(root: root, selection: $selection)
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            BottomBar(selection: $selection)
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(Theme.windowBackground)
        .preferredColorScheme(.dark)
        .navigationTitle(title)
        .onChange(of: coordinator.scanTarget) { _, _ in selection = [] }
        .onChange(of: selection) { _, newValue in
            // When browsing a cached tree, revalidate each folder we open so
            // anything changed on disk since the cache is refreshed in place.
            if let tip = newValue.last, tip.isDirectory {
                coordinator.revalidateOnNavigate(tip)
            }
        }
    }

    private var title: String {
        guard let root = coordinator.root, coordinator.capacityBytes > 0 else {
            return coordinator.root?.name ?? "DiskScope"
        }
        let used = max(0, coordinator.capacityBytes - coordinator.freeBytes)
        return "\(root.name) — \(ByteFormat.string(used)) used of \(ByteFormat.string(coordinator.capacityBytes))"
    }
}
