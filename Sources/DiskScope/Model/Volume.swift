import Foundation

/// A mounted, browsable volume that can be scanned.
struct Volume: Identifiable, Hashable {
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64

    var id: URL { url }
    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    /// Lists every locally-mounted, browsable volume (the boot drive plus any
    /// external disks). Network shares without capacity info are still included
    /// so the user can scan them.
    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey
        ]
        let fm = FileManager.default
        guard let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var result: [Volume] = []
        for url in urls {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if rv.volumeIsBrowsable == false { continue }
            let total = Int64(rv.volumeTotalCapacity ?? 0)
            let available = rv.volumeAvailableCapacityForImportantUsage
                ?? Int64(rv.volumeAvailableCapacity ?? 0)
            let name = rv.volumeName ?? url.lastPathComponent
            result.append(Volume(url: url, name: name, totalCapacity: total, availableCapacity: available))
        }
        return result
    }
}
