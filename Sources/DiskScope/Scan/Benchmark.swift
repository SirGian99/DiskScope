import Foundation

/// Developer benchmark, reachable from the CLI:
///
///     .build/release/DiskScope --benchmark /some/path
///
/// Drives the real `ScanCoordinator` headlessly by pumping the main run loop
/// until the scan completes, then prints wall-clock time and totals. Useful to
/// sanity-check throughput and to compare the reported total against `du`.
/// Not part of the shipping UI.
enum Benchmark {
    static func run() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--benchmark") else { return }
        let path = idx + 1 < args.count ? args[idx + 1] : NSHomeDirectory()

        if args.contains("--cachetest") {
            cacheTest(path)
        }
        if args.contains("--compare") {
            compareOldApproach(path)
        }

        let coordinator = ScanCoordinator()
        coordinator.crossMountPoints = false

        print("Scanning: \(path)")
        let start = Date()
        coordinator.scan(URL(fileURLWithPath: path))

        while coordinator.phase != .done && coordinator.phase != .cancelled {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let elapsed = Date().timeIntervalSince(start)

        let total = coordinator.root?.size ?? 0
        let items = coordinator.filesScanned
        let rate = elapsed > 0 ? Double(items) / elapsed : 0

        print(String(format: "elapsed:   %.2f s", elapsed))
        print("files:     \(items.formatted())")
        print(String(format: "rate:      %@ files/s", Int(rate).formatted()))
        print("total:     \(ByteFormat.string(total))  (\(total) bytes)")
        print("           compare with: du -sk \"\(path)\"  (× 1024)")

        if args.contains("--tree"), let root = coordinator.root {
            print("\ntop-level children (size · name):")
            for child in coordinator.sortedChildren(of: root).prefix(24) {
                print(String(format: "  %10@  %@", ByteFormat.string(child.size), child.name))
            }
        }
        exit(0)
    }

    /// Cold (scan + save cache) vs warm (load cache) open of the same target.
    private static func cacheTest(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let cacheURL = DiskCache.cacheURL(for: url) {
            try? FileManager.default.removeItem(at: cacheURL)
        }

        // Cold: no cache present -> full scan + save.
        let cold = ScanCoordinator()
        var t = Date()
        cold.open(url)
        pump(until: { cold.phase == .done || cold.phase == .cancelled })
        let coldElapsed = Date().timeIntervalSince(t)
        let coldTotal = cold.root?.size ?? 0
        // Let the async cache write finish.
        pump(for: 1.5)

        // Warm: cache present -> instant load.
        let warm = ScanCoordinator()
        t = Date()
        warm.open(url)
        pump(until: { warm.phase == .done || warm.phase == .cancelled })
        let warmElapsed = Date().timeIntervalSince(t)
        let warmTotal = warm.root?.size ?? 0

        print("[cache test] \(path)")
        print(String(format: "  cold (scan+save): %.3f s   total: %@", coldElapsed, ByteFormat.string(coldTotal)))
        print(String(format: "  warm (from cache): %.3f s   total: %@", warmElapsed, ByteFormat.string(warmTotal)))
        let speedup = warmElapsed > 0 ? coldElapsed / warmElapsed : 0
        print(String(format: "  speedup: %.1fx   freshness: %@   totals match: %@",
                     speedup, "\(warm.freshness)", coldTotal == warmTotal ? "YES ✅" : "NO ❌"))
        print("")
        exit(0)
    }

    private static func pump(until done: () -> Bool) {
        while !done() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
    private static func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// The original approach: single-threaded FileManager recursion with a
    /// per-file `resourceValues` call. Kept only for A/B measurement.
    private static func compareOldApproach(_ path: String) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var files = 0
        var total: Int64 = 0

        func walk(_ url: URL) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys), options: []) else { return }
            for child in contents {
                let rv = try? child.resourceValues(forKeys: keys)
                let isSymlink = rv?.isSymbolicLink ?? false
                let isDir = (rv?.isDirectory ?? false) && !isSymlink
                if isDir {
                    walk(child)
                } else {
                    files += 1
                    total += Int64(rv?.totalFileAllocatedSize ?? rv?.fileAllocatedSize ?? 0)
                }
            }
        }

        let start = Date()
        walk(URL(fileURLWithPath: path))
        let elapsed = Date().timeIntervalSince(start)
        print("[old: serial FileManager]")
        print(String(format: "  elapsed: %.2f s   files: %@   total: %@",
                     elapsed, files.formatted(), ByteFormat.string(total)))
        print("")
    }
}
