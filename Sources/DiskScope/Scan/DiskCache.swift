import Foundation

/// Metadata stored alongside a cached tree, used to judge whether the cache is
/// still trustworthy without re-walking the whole disk.
struct CacheMeta {
    let targetPath: String
    let scanDate: Date
    let capacityBytes: Int64
    let freeBytes: Int64
}

struct LoadedCache {
    let root: FileNode
    let meta: CacheMeta
}

/// Persists a scanned tree to Application Support and reloads it quickly.
///
/// Format is a compact, hand-rolled binary blob (Codable/JSON would be far too
/// large and slow for millions of nodes). Layout:
///
///   magic "DSC1" | version u32 | scanDate f64 | capacity i64 | free i64
///   targetPath (u16 len + utf8) | tree (pre-order)
///
/// Each node: name (u16 len + utf8) | flags u8 | size i64 | mtime i64 | childCount u32
enum DiskCache {
    private static let magic: [UInt8] = Array("DSC1".utf8)
    // v2: trees are now inode-deduplicated (firmlink/hardlink aware). Older
    // caches predate dedup and are discarded on load so a fresh scan runs.
    private static let version: UInt32 = 2

    private static let flagDir: UInt8 = 1 << 0
    private static let flagInaccessible: UInt8 = 1 << 1

    // MARK: - Location

    private static func cacheDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("DiskScope/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(for target: URL) -> URL? {
        guard let dir = cacheDirectory() else { return nil }
        let key = fnv1a(target.standardizedFileURL.path)
        return dir.appendingPathComponent(String(format: "%016llx.dscache", key))
    }

    /// Stable 64-bit hash for the cache filename (path is also stored in the
    /// header and re-checked on load, so collisions can't cause a wrong load).
    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x00000100000001B3
        }
        return hash
    }

    // MARK: - Save

    static func save(root: FileNode, meta: CacheMeta) {
        guard let url = cacheURL(for: URL(fileURLWithPath: meta.targetPath)) else { return }

        var data = Data()
        data.reserveCapacity(8 * 1024 * 1024)
        data.append(contentsOf: magic)
        append(&data, version)
        append(&data, meta.scanDate.timeIntervalSince1970.bitPattern)
        append(&data, UInt64(bitPattern: meta.capacityBytes))
        append(&data, UInt64(bitPattern: meta.freeBytes))
        appendString(&data, meta.targetPath)
        writeNode(root, into: &data)

        try? data.write(to: url, options: .atomic)
    }

    private static func writeNode(_ node: FileNode, into data: inout Data) {
        appendString(&data, node.name)
        var flags: UInt8 = 0
        if node.isDirectory { flags |= flagDir }
        if node.inaccessible { flags |= flagInaccessible }
        data.append(flags)
        append(&data, UInt64(bitPattern: node.size))
        append(&data, UInt64(bitPattern: node.mtime))
        append(&data, UInt32(node.children.count))
        for child in node.children {
            writeNode(child, into: &data)
        }
    }

    // MARK: - Load

    static func load(target: URL) -> LoadedCache? {
        guard let url = cacheURL(for: target),
              let data = try? Data(contentsOf: url) else { return nil }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> LoadedCache? in
            guard let base = raw.baseAddress, raw.count > 4 else { return nil }
            var cursor = 0

            for byte in magic {
                if raw[cursor] != byte { return nil }
                cursor += 1
            }
            let fileVersion = readU32(base, &cursor)
            guard fileVersion == version else { return nil }

            let scanDate = Date(timeIntervalSince1970: Double(bitPattern: readU64(base, &cursor)))
            let capacity = Int64(bitPattern: readU64(base, &cursor))
            let free = Int64(bitPattern: readU64(base, &cursor))
            guard let storedPath = readString(base, &cursor, limit: raw.count) else { return nil }

            // Guard against hash collisions.
            guard storedPath == target.standardizedFileURL.path else { return nil }

            let root = readNode(base, &cursor, limit: raw.count,
                                parent: nil, rootURL: target)
            let meta = CacheMeta(targetPath: storedPath, scanDate: scanDate,
                                 capacityBytes: capacity, freeBytes: free)
            return LoadedCache(root: root, meta: meta)
        }
    }

    private static func readNode(_ base: UnsafeRawPointer, _ cursor: inout Int, limit: Int,
                                 parent: FileNode?, rootURL: URL?) -> FileNode {
        let name = readString(base, &cursor, limit: limit) ?? ""
        let flags = base.load(fromByteOffset: cursor, as: UInt8.self); cursor += 1
        let size = Int64(bitPattern: readU64(base, &cursor))
        let mtime = Int64(bitPattern: readU64(base, &cursor))
        let childCount = Int(readU32(base, &cursor))

        let node = FileNode(name: name,
                            isDirectory: flags & flagDir != 0,
                            parent: parent,
                            rootURL: rootURL)
        node.size = size
        node.mtime = mtime
        node.inaccessible = flags & flagInaccessible != 0
        node.scanned = true

        if childCount > 0 {
            var children: [FileNode] = []
            children.reserveCapacity(childCount)
            for _ in 0..<childCount {
                children.append(readNode(base, &cursor, limit: limit, parent: node, rootURL: nil))
            }
            node.children = children
        }
        return node
    }

    // MARK: - Primitive encode/decode

    private static func append(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func append(_ data: inout Data, _ value: UInt64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func appendString(_ data: inout Data, _ s: String) {
        let bytes = Array(s.utf8.prefix(0xFFFF))
        append(&data, UInt16(bytes.count))
        data.append(contentsOf: bytes)
    }
    private static func append(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readU16(_ base: UnsafeRawPointer, _ cursor: inout Int) -> UInt16 {
        let v = base.loadUnaligned(fromByteOffset: cursor, as: UInt16.self)
        cursor += 2
        return UInt16(littleEndian: v)
    }
    private static func readU32(_ base: UnsafeRawPointer, _ cursor: inout Int) -> UInt32 {
        let v = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
        cursor += 4
        return UInt32(littleEndian: v)
    }
    private static func readU64(_ base: UnsafeRawPointer, _ cursor: inout Int) -> UInt64 {
        let v = base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
        cursor += 8
        return UInt64(littleEndian: v)
    }
    private static func readString(_ base: UnsafeRawPointer, _ cursor: inout Int, limit: Int) -> String? {
        let count = Int(readU16(base, &cursor))
        guard cursor + count <= limit else { return nil }
        let s = String(bytes: UnsafeRawBufferPointer(start: base.advanced(by: cursor), count: count),
                       encoding: .utf8)
        cursor += count
        return s
    }
}
