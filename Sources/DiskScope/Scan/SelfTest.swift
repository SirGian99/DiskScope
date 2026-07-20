import Foundation

/// Developer self-test, reachable from the CLI:
///
///     .build/debug/DiskScope --selftest /some/path
///
/// Cross-checks `FastDirectoryScanner` (getattrlistbulk) against `FileManager`
/// for a single directory: same set of names, and per-file allocated sizes that
/// agree. Prints a summary and exits. Not part of the shipping UI.
enum SelfTest {
    static func run() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--selftest") else { return }
        let path = idx + 1 < args.count ? args[idx + 1] : NSHomeDirectory()
        print("Self-test on: \(path)\n")

        // Fast path.
        let fast: [DirEntry]
        switch FastDirectoryScanner.list(atPath: path) {
        case .ok(let e): fast = e
        case .denied: print("FastDirectoryScanner: DENIED"); exit(1)
        case .unsupported: print("FastDirectoryScanner: UNSUPPORTED here"); exit(1)
        }

        // Reference path via FileManager.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .nameKey]
        let url = URL(fileURLWithPath: path)
        let refURLs = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [])) ?? []

        var refSizes: [String: Int64] = [:]
        var refDirs: Set<String> = []
        for u in refURLs {
            let rv = try? u.resourceValues(forKeys: keys)
            let name = rv?.name ?? u.lastPathComponent
            let isSymlink = rv?.isSymbolicLink ?? false
            let isDir = (rv?.isDirectory ?? false) && !isSymlink
            if isDir { refDirs.insert(name) }
            else { refSizes[name] = Int64(rv?.totalFileAllocatedSize ?? rv?.fileAllocatedSize ?? 0) }
        }

        let fastNames = Set(fast.map(\.name))
        let refNames = Set(refURLs.map { (try? $0.resourceValues(forKeys: [.nameKey]))?.name ?? $0.lastPathComponent })

        let missing = refNames.subtracting(fastNames)
        let extra = fastNames.subtracting(refNames)

        print("entries  fast=\(fast.count)  fileManager=\(refNames.count)")
        print("names    missing=\(missing.count)  extra=\(extra.count)")
        if !missing.isEmpty { print("  missing: \(missing.prefix(10))") }
        if !extra.isEmpty { print("  extra:   \(extra.prefix(10))") }

        // Compare file sizes (allocated sizes can differ by a block due to
        // resource-fork accounting; flag only large disagreements).
        var sizeMismatches = 0
        var fastTotal: Int64 = 0
        for e in fast where !e.isDirectory {
            fastTotal += e.allocatedSize
            if let ref = refSizes[e.name] {
                let diff = abs(ref - e.allocatedSize)
                if diff > 4096 && diff > ref / 10 {
                    sizeMismatches += 1
                    if sizeMismatches <= 5 {
                        print("  size mismatch \(e.name): fast=\(e.allocatedSize) ref=\(ref)")
                    }
                }
            }
        }
        let refTotal = refSizes.values.reduce(0, +)
        print("file bytes  fast=\(fastTotal)  fileManager=\(refTotal)  mismatches=\(sizeMismatches)")

        let ok = missing.isEmpty && extra.isEmpty && sizeMismatches == 0
        print("\n\(ok ? "PASS ✅" : "DIFFERENCES ⚠️")")
        exit(ok ? 0 : 2)
    }
}
