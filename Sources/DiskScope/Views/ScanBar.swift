import SwiftUI

/// Top bar: volume picker, rescan, cache-freshness banner, and live progress.
struct ScanBar: View {
    @EnvironmentObject var coordinator: ScanCoordinator
    @Binding var selection: [FileNode]
    @State private var volumes: [Volume] = []

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(volumes) { volume in
                    Button {
                        open(volume.url)
                    } label: {
                        Text("\(volume.name) — \(ByteFormat.string(volume.usedCapacity)) of \(ByteFormat.string(volume.totalCapacity))")
                    }
                }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.fill")
                    Text(coordinator.root?.name ?? "Select Volume")
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            freshnessBanner

            Spacer()

            switch coordinator.phase {
            case .loadingCache:
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Loading cache…").font(.system(size: 11)).foregroundStyle(.secondary)
            case .scanning:
                ProgressView().controlSize(.small).scaleEffect(0.8)
                progressText
                Button("Stop") { coordinator.cancel() }
            case .done, .cancelled:
                progressText
                rescanButton
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { volumes = Volume.mounted() }
    }

    @ViewBuilder private var freshnessBanner: some View {
        switch coordinator.freshness {
        case .live:
            EmptyView()
        case .cached(let date):
            banner(icon: "clock.arrow.circlepath",
                   text: "Cached \(Self.relative(date))",
                   tint: .secondary)
        case .stale(let date, let drift):
            banner(icon: "exclamationmark.triangle.fill",
                   text: "Cached \(Self.relative(date)) · \(ByteFormat.string(drift)) changed since",
                   tint: .orange)
        }
    }

    private func banner(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var rescanButton: some View {
        Button {
            selection = []
            coordinator.rescan()
        } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
        }
        .help("Discard the cache and scan again")
    }

    private var progressText: some View {
        Text("\(coordinator.filesScanned.formatted()) items • \(ByteFormat.string(coordinator.bytesScanned))")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func open(_ url: URL) {
        selection = []
        coordinator.open(url)
        volumes = Volume.mounted()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
