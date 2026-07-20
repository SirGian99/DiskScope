import Foundation
import SwiftUI

/// Drives filesystem scanning and publishes progress and results to the UI.
///
/// Scanning is parallel: a small pool of workers pulls directories from a shared
/// LIFO stack, enumerates each with `FastDirectoryScanner` (one bulk syscall per
/// directory), and pushes subdirectories back. File sizes are summed locally per
/// directory; directory totals propagate up the tree once per completed subtree
/// rather than once per file, so lock traffic is proportional to the number of
/// directories, not files.
///
/// Threading:
/// - The tree (`FileNode`) is mutated only under `treeLock`. The UI reads it
///   only through `sortedChildren(of:)`, which copies under the same lock.
/// - `@Published` values are written only on the main thread.
/// - A monotonically increasing `generation` supersedes stale scans/refreshes:
///   any worker or completion for an old generation is a no-op.
final class ScanCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, loadingCache, scanning, done, cancelled }

    enum Freshness: Equatable {
        case live                       // freshly scanned this session
        case cached(Date)               // from cache, no material drift
        case stale(Date, driftBytes: Int64)  // from cache, disk usage moved
    }

    @Published var root: FileNode?
    @Published var phase: Phase = .idle
    @Published var scanTarget: URL?
    @Published var filesScanned: Int = 0
    @Published var bytesScanned: Int64 = 0
    @Published var currentPath: String = ""
    @Published var refreshTick: Int = 0
    @Published var capacityBytes: Int64 = 0
    @Published var freeBytes: Int64 = 0
    @Published private(set) var freshness: Freshness = .live

    /// When false (default), the scan stays on the target's own volume rather
    /// than descending into other mounted disks under `/Volumes`.
    var crossMountPoints = false

    private let treeLock = NSLock()
    private let workQueue = DispatchQueue(label: "io.diskscope.scan", qos: .userInitiated)
    private let poolQueue = DispatchQueue(label: "io.diskscope.pool", qos: .userInitiated, attributes: .concurrent)
    private let workerCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

    // Guarded by treeLock.
    private var generation = 0
    private var cancelRequested = false
    private var bgFiles = 0
    private var bgBytes: Int64 = 0
    private var bgPath = ""
    private var lastFlush = Date.distantPast

    private var treeIsFromCache = false
    private var cacheMeta: CacheMeta?
    private var revalidatedNodes = Set<ObjectIdentifier>()
    private var saveWorkItem: DispatchWorkItem?

    /// Directory identities already counted in the current scan, so a directory
    /// reachable via more than one path (firmlink, hardlink) is counted once.
    private var visitedDirs = Set<DirKey>()

    private struct DirKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    // MARK: - Reading (main thread)

    /// A directory's children, copied and sorted largest-first. Safe during a scan.
    func sortedChildren(of node: FileNode) -> [FileNode] {
        treeLock.lock()
        defer { treeLock.unlock() }
        return node.children.sorted { a, b in
            a.size != b.size
                ? a.size > b.size
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Entry points

    /// Opens a target, preferring a valid cache for an instant first paint and
    /// falling back to a full scan when there is no cache.
    func open(_ target: URL) {
        let gen = beginGeneration()
        phase = .loadingCache
        scanTarget = target
        resetProgress()

        workQueue.async { [weak self] in
            guard let self else { return }
            if let cache = DiskCache.load(target: target) {
                DispatchQueue.main.async {
                    guard self.isCurrent(gen) else { return }
                    self.applyLoadedCache(cache, target: target)
                }
            } else {
                DispatchQueue.main.async {
                    guard self.isCurrent(gen) else { return }
                    self.startScan(target, generation: gen)
                }
            }
        }
    }

    /// Forces a fresh scan, ignoring (and then overwriting) any cache.
    func rescan() {
        guard let target = scanTarget else { return }
        let gen = beginGeneration()
        startScan(target, generation: gen)
    }

    func scan(_ target: URL) {
        let gen = beginGeneration()
        startScan(target, generation: gen)
    }

    func cancel() {
        treeLock.lock()
        cancelRequested = true
        treeLock.unlock()
    }

    // MARK: - Full scan

    private func startScan(_ target: URL, generation gen: Int) {
        let displayName = (try? target.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            ?? target.lastPathComponent
        let rootNode = FileNode(name: displayName, isDirectory: true, parent: nil, rootURL: target)
        let rootIdentity = Self.identity(of: target)
        rootNode.mtime = rootIdentity.mtime
        rootNode.deviceID = rootIdentity.dev
        rootNode.inode = rootIdentity.ino

        root = rootNode
        scanTarget = target
        phase = .scanning
        freshness = .live
        treeIsFromCache = false
        revalidatedNodes.removeAll()
        resetProgress()
        readCapacity(of: target)

        treeLock.lock(); visitedDirs.removeAll(keepingCapacity: true); treeLock.unlock()

        let rootDevice = rootIdentity.dev

        runPool(initial: [rootNode], rootDeviceID: rootDevice,
                shouldContinue: { [weak self] in self?.isCurrent(gen) ?? false }) { [weak self] in
            guard let self else { return }
            let cancelled = self.wasCancelled()
            let (f, b) = self.progressSnapshot()
            let capacity = self.readLiveCapacity(of: target)
            DispatchQueue.main.async {
                guard self.isCurrent(gen) else { return }
                rootNode.scanned = true
                self.filesScanned = f
                self.bytesScanned = b
                self.phase = cancelled ? .cancelled : .done
                self.refreshTick &+= 1
                if !cancelled {
                    self.freshness = .live
                    self.saveCache(root: rootNode, target: target,
                                   capacity: capacity.total, free: capacity.free)
                }
            }
        }
    }

    // MARK: - Worker pool

    private func runPool(initial: [FileNode],
                         rootDeviceID: Int32,
                         shouldContinue: @escaping () -> Bool,
                         completion: @escaping () -> Void) {
        let condition = NSCondition()
        // Breadth-first (FIFO) queue: shallower directories are processed first,
        // so a directory reachable via both a short firmlink path (e.g. /Users)
        // and a deep real path (/System/Volumes/Data/Users) is counted under the
        // shallow, user-expected location. `head` avoids O(n) removeFirst; the
        // queue is compacted once it is mostly drained.
        var queue = initial
        var head = 0
        var busy = 0
        let group = DispatchGroup()

        func worker() {
            while true {
                condition.lock()
                while head >= queue.count && busy > 0 && shouldContinue() {
                    condition.wait()
                }
                if !shouldContinue() {
                    condition.broadcast(); condition.unlock(); return
                }
                if head >= queue.count && busy == 0 {
                    condition.broadcast(); condition.unlock(); return
                }
                let node = queue[head]
                head += 1
                if head > 8192 && head * 2 > queue.count {
                    queue.removeFirst(head); head = 0
                }
                busy += 1
                condition.unlock()

                let subdirs = self.processDirectory(node, rootDeviceID: rootDeviceID,
                                                    shouldContinue: shouldContinue)

                condition.lock()
                queue.append(contentsOf: subdirs)
                busy -= 1
                condition.broadcast()
                condition.unlock()
            }
        }

        for _ in 0..<workerCount {
            group.enter()
            poolQueue.async { worker(); group.leave() }
        }
        group.notify(queue: workQueue) { completion() }
    }

    /// Enumerates one directory, records its children and own-file total, and
    /// returns its subdirectories for further scanning. If it has no
    /// subdirectories, its subtree is complete and it propagates up immediately.
    private func processDirectory(_ node: FileNode, rootDeviceID: Int32,
                                  shouldContinue: () -> Bool) -> [FileNode] {
        if !shouldContinue() { return [] }

        // Claim this directory's identity. If another path already reached the
        // same directory (a firmlink or hardlinked directory), don't re-count
        // it — leave it at zero and finish its accounting so the parent total
        // stays correct.
        if node.inode != 0 {
            treeLock.lock()
            let claimed = visitedDirs.insert(DirKey(dev: node.deviceID, ino: node.inode)).inserted
            treeLock.unlock()
            if !claimed {
                treeLock.lock(); node.scanned = true; treeLock.unlock()
                completeSubtree(node)
                return []
            }
        }

        let entries: [DirEntry]
        switch FastDirectoryScanner.list(atPath: node.url.path) {
        case .ok(let e):
            entries = e
        case .unsupported:
            entries = Self.fallbackList(node.url)
        case .denied:
            treeLock.lock(); node.inaccessible = true; node.scanned = true; treeLock.unlock()
            completeSubtree(node)
            return []
        }

        var children: [FileNode] = []
        children.reserveCapacity(entries.count)
        var subdirs: [FileNode] = []
        var ownFileBytes: Int64 = 0
        var ownFileCount = 0

        for entry in entries {
            let isDir = entry.isDirectory
            // Skip directories that live on a different volume (mount points,
            // external drives) unless crossing is explicitly enabled. deviceID
            // 0 means "unknown" (fallback enumeration) and is never skipped.
            if isDir, !crossMountPoints, rootDeviceID != 0,
               entry.deviceID != 0, entry.deviceID != rootDeviceID {
                continue
            }
            let child = FileNode(name: entry.name, isDirectory: isDir, parent: node)
            child.mtime = entry.mtime
            child.deviceID = entry.deviceID
            child.inode = entry.inode
            if isDir {
                child.pendingSubdirs = 0
                subdirs.append(child)
            } else {
                child.size = entry.allocatedSize
                child.scanned = true
                ownFileBytes += entry.allocatedSize
                ownFileCount += 1
            }
            children.append(child)
        }

        treeLock.lock()
        node.children = children
        node.size += ownFileBytes
        node.pendingSubdirs = subdirs.count
        treeLock.unlock()

        publishProgress(files: ownFileCount, bytes: ownFileBytes, path: node.url.path)

        if subdirs.isEmpty {
            completeSubtree(node)
        }
        return subdirs
    }

    /// Marks a fully-measured subtree done and folds its total into ancestors,
    /// cascading upward for any ancestor that thereby becomes complete.
    private func completeSubtree(_ node: FileNode) {
        treeLock.lock()
        var current = node
        current.scanned = true
        while let parent = current.parent {
            parent.size += current.size
            parent.pendingSubdirs -= 1
            if parent.pendingSubdirs == 0 {
                parent.scanned = true
                current = parent
            } else {
                break
            }
        }
        treeLock.unlock()
    }

    // MARK: - Cache: apply + validate

    private func applyLoadedCache(_ cache: LoadedCache, target: URL) {
        root = cache.root
        scanTarget = target
        phase = .done
        treeIsFromCache = true
        cacheMeta = cache.meta
        capacityBytes = cache.meta.capacityBytes
        revalidatedNodes.removeAll()

        // Count nodes/bytes shown from cache for the status line.
        bytesScanned = cache.root.size
        filesScanned = 0

        // O(1) global validity: compare live free space to what was recorded.
        let live = readLiveCapacity(of: target)
        freeBytes = live.free
        if live.total > 0 { capacityBytes = live.total }
        let drift = abs(live.free - cache.meta.freeBytes)
        let threshold = max(Int64(500_000_000), (live.total > 0 ? live.total : cache.meta.capacityBytes) / 100)
        freshness = drift > threshold ? .stale(cache.meta.scanDate, driftBytes: drift)
                                      : .cached(cache.meta.scanDate)
        refreshTick &+= 1
    }

    /// Called when the user navigates into a directory. For a cached tree, does a
    /// cheap single-directory mtime check; if the folder changed on disk since
    /// the cache was written, its subtree is refreshed in the background.
    func revalidateOnNavigate(_ node: FileNode) {
        guard treeIsFromCache, node.isDirectory, !node.inaccessible else { return }
        guard let target = scanTarget, let rootNode = root else { return }
        let key = ObjectIdentifier(node)
        guard !revalidatedNodes.contains(key) else { return }
        revalidatedNodes.insert(key)

        let gen = currentGeneration()
        let url = node.url
        let cachedMtime = node.mtime
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let liveMtime = Self.directoryMtime(url), liveMtime != cachedMtime else { return }
            self.refreshSubtree(node, newMtime: liveMtime, generation: gen,
                                target: target, rootNode: rootNode)
        }
    }

    private func refreshSubtree(_ node: FileNode, newMtime: Int64, generation gen: Int,
                                target: URL, rootNode: FileNode) {
        let identity = Self.identity(of: node.url)

        treeLock.lock()
        guard gen == generation else { treeLock.unlock(); return }
        let oldSize = node.size
        node.children = []
        node.size = 0
        node.pendingSubdirs = 0
        node.scanned = false
        node.mtime = newMtime
        node.deviceID = identity.dev
        node.inode = identity.ino
        visitedDirs.removeAll(keepingCapacity: true)
        treeLock.unlock()

        runPool(initial: [node], rootDeviceID: identity.dev,
                shouldContinue: { [weak self] in self?.isCurrent(gen) ?? false }) { [weak self] in
            guard let self else { return }
            self.treeLock.lock()
            let stillCurrent = gen == self.generation
            let newSize = node.size
            if stillCurrent {
                var ancestor = node.parent
                while let a = ancestor {
                    a.size += (newSize - oldSize)
                    ancestor = a.parent
                }
            }
            self.treeLock.unlock()
            guard stillCurrent else { return }
            DispatchQueue.main.async { self.refreshTick &+= 1 }
            self.scheduleCacheSave(root: rootNode, target: target)
        }
    }

    // MARK: - Cache: save

    private func saveCache(root: FileNode, target: URL, capacity: Int64, free: Int64) {
        cacheMeta = CacheMeta(targetPath: target.standardizedFileURL.path,
                              scanDate: Date(), capacityBytes: capacity, freeBytes: free)
        let meta = cacheMeta!
        workQueue.async {
            DiskCache.save(root: root, meta: meta)
        }
    }

    /// Debounced re-save after a subtree refresh or a trash operation.
    private func scheduleCacheSave(root: FileNode, target: URL) {
        saveWorkItem?.cancel()
        let scanDate = cacheMeta?.scanDate ?? Date()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let capacity = self.readLiveCapacity(of: target)
            let meta = CacheMeta(targetPath: target.standardizedFileURL.path,
                                 scanDate: scanDate,
                                 capacityBytes: capacity.total, freeBytes: capacity.free)
            DiskCache.save(root: root, meta: meta)
        }
        saveWorkItem = item
        workQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // MARK: - Generation / cancellation

    private func beginGeneration() -> Int {
        treeLock.lock()
        generation += 1
        cancelRequested = false
        let gen = generation
        treeLock.unlock()
        return gen
    }
    private func currentGeneration() -> Int {
        treeLock.lock(); defer { treeLock.unlock() }
        return generation
    }
    private func isCurrent(_ gen: Int) -> Bool {
        treeLock.lock(); defer { treeLock.unlock() }
        return gen == generation && !cancelRequested
    }
    private func wasCancelled() -> Bool {
        treeLock.lock(); defer { treeLock.unlock() }
        return cancelRequested
    }

    // MARK: - Progress

    private func resetProgress() {
        filesScanned = 0
        bytesScanned = 0
        currentPath = ""
        treeLock.lock()
        bgFiles = 0; bgBytes = 0; bgPath = ""; lastFlush = .distantPast
        treeLock.unlock()
    }

    private func publishProgress(files: Int, bytes: Int64, path: String) {
        treeLock.lock()
        bgFiles += files
        bgBytes += bytes
        bgPath = path
        let now = Date()
        let due = now.timeIntervalSince(lastFlush) > 0.08
        if due { lastFlush = now }
        let f = bgFiles, b = bgBytes, p = bgPath
        treeLock.unlock()

        guard due else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.filesScanned = f
            self.bytesScanned = b
            self.currentPath = p
            self.refreshTick &+= 1
        }
    }

    private func progressSnapshot() -> (Int, Int64) {
        treeLock.lock(); defer { treeLock.unlock() }
        return (bgFiles, bgBytes)
    }

    // MARK: - Capacity helpers

    private func readCapacity(of url: URL) {
        let cap = readLiveCapacity(of: url)
        capacityBytes = cap.total
        freeBytes = cap.free
    }

    private func readLiveCapacity(of url: URL) -> (total: Int64, free: Int64) {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        let total = Int64(rv.volumeTotalCapacity ?? 0)
        let free = rv.volumeAvailableCapacityForImportantUsage ?? Int64(rv.volumeAvailableCapacity ?? 0)
        return (total, free)
    }

    // MARK: - Volume + mtime helpers

    static func directoryMtime(_ url: URL) -> Int64? {
        var st = stat()
        return url.path.withCString { lstat($0, &st) == 0 ? Int64(st.st_mtimespec.tv_sec) : nil }
    }

    /// Filesystem identity of a path: device, inode and modification time.
    /// All zero on failure.
    static func identity(of url: URL) -> (dev: Int32, ino: UInt64, mtime: Int64) {
        var st = stat()
        guard url.path.withCString({ lstat($0, &st) == 0 }) else { return (0, 0, 0) }
        return (Int32(truncatingIfNeeded: st.st_dev), UInt64(st.st_ino), Int64(st.st_mtimespec.tv_sec))
    }

    // MARK: - Tree edit (after trashing)

    func removeFromTree(_ node: FileNode) {
        treeLock.lock()
        if let parent = node.parent,
           let idx = parent.children.firstIndex(where: { $0 === node }) {
            parent.children.remove(at: idx)
            var ancestor: FileNode? = parent
            while let a = ancestor {
                a.size -= node.size
                ancestor = a.parent
            }
        }
        treeLock.unlock()
        refreshTick &+= 1
        if let target = scanTarget, let rootNode = root {
            scheduleCacheSave(root: rootNode, target: target)
        }
    }

    // MARK: - Fallback enumeration (non-getattrlistbulk filesystems)

    private static func fallbackList(_ url: URL) -> [DirEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []) else { return [] }
        return urls.map { child in
            let rv = try? child.resourceValues(forKeys: keys)
            let isSymlink = rv?.isSymbolicLink ?? false
            let isDir = (rv?.isDirectory ?? false) && !isSymlink
            let size = Int64(rv?.totalFileAllocatedSize ?? rv?.fileAllocatedSize ?? rv?.fileSize ?? 0)
            let mtime = Int64(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            return DirEntry(name: rv?.name ?? child.lastPathComponent,
                            isDirectory: isDir, isSymlink: isSymlink,
                            allocatedSize: isDir ? 0 : size, mtime: mtime,
                            deviceID: 0, inode: 0)
        }
    }
}
