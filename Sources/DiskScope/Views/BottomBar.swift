import SwiftUI

/// Bottom bar: disk capacity gauge, the selected item, and actions.
struct BottomBar: View {
    @EnvironmentObject var coordinator: ScanCoordinator
    @Binding var selection: [FileNode]
    @State private var confirmTrash = false
    @State private var trashError: String?

    private var tip: FileNode? { selection.last }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            diskSummary
                .frame(width: 200, alignment: .leading)

            Spacer(minLength: 8)

            if let tip {
                VStack(spacing: 1) {
                    Text(tip.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(ByteFormat.string(tip.size))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Text(tip.url.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 380)
                }
            } else {
                Text("No selection")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    if let url = tip?.url { FileActions.reveal(url) }
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }
                .disabled(tip == nil)

                Button(role: .destructive) {
                    confirmTrash = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(tip == nil)
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .frame(width: 240, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .confirmationDialog(trashPrompt, isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { performTrash() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t move to Trash",
               isPresented: Binding(get: { trashError != nil },
                                    set: { if !$0 { trashError = nil } })) {
            Button("OK") { trashError = nil }
        } message: {
            Text(trashError ?? "")
        }
    }

    @ViewBuilder private var diskSummary: some View {
        if coordinator.capacityBytes > 0 {
            let used = max(0, coordinator.capacityBytes - coordinator.freeBytes)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ByteFormat.string(used)) used • \(ByteFormat.string(coordinator.freeBytes)) free")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                CapacityBar(used: used, total: coordinator.capacityBytes)
                    .frame(height: 6)
            }
        }
    }

    private var trashPrompt: String {
        guard let tip else { return "" }
        return "Move “\(tip.name)” (\(ByteFormat.string(tip.size))) to the Trash?"
    }

    private func performTrash() {
        guard let node = tip else { return }
        let url = node.url
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileActions.moveToTrash(url)
                DispatchQueue.main.async {
                    coordinator.removeFromTree(node)
                    if !selection.isEmpty { selection.removeLast() }
                }
            } catch {
                DispatchQueue.main.async { trashError = error.localizedDescription }
            }
        }
    }
}

/// A thin used/free capacity gauge.
private struct CapacityBar: View {
    let used: Int64
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(1, Double(used) / Double(total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.barColor, Theme.barColor.opacity(0.7)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
    }
}
