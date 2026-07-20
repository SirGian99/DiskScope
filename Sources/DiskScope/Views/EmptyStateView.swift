import SwiftUI

/// Shown before any scan: a prompt plus quick buttons for each mounted volume.
struct EmptyStateView: View {
    @EnvironmentObject var coordinator: ScanCoordinator
    @State private var volumes: [Volume] = []

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "internaldrive")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Scan a volume to see what’s using your space")
                    .font(.title3)
                Text("Everything runs locally. DiskScope never connects to the network.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ForEach(volumes) { volume in
                    Button {
                        coordinator.open(volume.url)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "externaldrive").font(.system(size: 22))
                            Text(volume.name).font(.system(size: 12, weight: .medium))
                            Text(ByteFormat.string(volume.totalCapacity))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 110, height: 86)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Choose Folder…") { chooseFolder() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .onAppear { volumes = Volume.mounted() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.open(url)
        }
    }
}
