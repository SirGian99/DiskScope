import Darwin

/// One directory entry as returned by the fast enumerator.
struct DirEntry {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let allocatedSize: Int64   // physical bytes on disk (0 for directories)
    let mtime: Int64           // modification time, seconds since 1970
    let deviceID: Int32        // st_dev — differs at a mount point / other volume
    let inode: UInt64          // file id — same value for firmlink/hardlink aliases
}

enum DirListing {
    case ok([DirEntry])
    case denied        // couldn't open / read the directory
    case unsupported   // filesystem doesn't support getattrlistbulk — use fallback
}

/// High-throughput directory enumeration via `getattrlistbulk(2)`.
///
/// A single syscall returns name, object type, on-disk allocated size and
/// modification time for many entries at once — avoiding the per-file `stat`
/// that dominates the cost of `FileManager` + `URLResourceValues`. This is the
/// same class of technique fast disk-usage tools use.
enum FastDirectoryScanner {

    // Attribute bits (stable kernel ABI). Declared explicitly to avoid Swift's
    // signed/unsigned import ambiguity around ATTR_CMN_RETURNED_ATTRS (0x80000000).
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let cmnName: UInt32          = 0x0000_0001
    private static let cmnDevID: UInt32         = 0x0000_0002
    private static let cmnObjType: UInt32       = 0x0000_0008
    private static let cmnModTime: UInt32       = 0x0000_0400
    private static let cmnFileID: UInt32        = 0x0200_0000
    private static let fileAllocSize: UInt32    = 0x0000_0004

    // fsobj_type_t (vnode types) values.
    private static let vtypeDir: UInt32  = 2   // VDIR
    private static let vtypeLink: UInt32 = 5   // VLNK

    static func list(atPath path: String) -> DirListing {
        let fd = path.withCString { open($0, O_RDONLY, 0) }
        if fd < 0 {
            return .denied
        }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = cmnReturnedAttrs | cmnName | cmnDevID | cmnObjType | cmnModTime | cmnFileID
        attrList.fileattr = fileAllocSize

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [DirEntry] = []

        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count == 0 { break }             // no more entries
            if count < 0 {
                let err = errno
                if entries.isEmpty && (err == ENOTSUP || err == EINVAL) {
                    return .unsupported
                }
                break                            // partial results are still useful
            }
            parseBatch(buffer, count: Int(count), into: &entries)
        }

        return .ok(entries)
    }

    /// Parses `count` packed entries. Each entry is length-prefixed; fields are
    /// packed without alignment padding, so every read is unaligned. The
    /// `returned` attribute set tells us which fields are present for this
    /// entry (directories omit the file-only allocated size).
    private static func parseBatch(_ base: UnsafeRawPointer, count: Int, into entries: inout [DirEntry]) {
        var entry = base
        for _ in 0..<count {
            let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
            var field = entry.advanced(by: MemoryLayout<UInt32>.size)

            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field = field.advanced(by: MemoryLayout<attribute_set_t>.size)

            var name = ""
            var deviceID: Int32 = 0
            var objType: UInt32 = 0
            var mtime: Int64 = 0
            var inode: UInt64 = 0
            var allocSize: Int64 = 0

            if returned.commonattr & cmnName != 0 {
                let ref = field.loadUnaligned(as: attrreference_t.self)
                let namePtr = field.advanced(by: Int(ref.attr_dataoffset))
                name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
                field = field.advanced(by: MemoryLayout<attrreference_t>.size)
            }
            if returned.commonattr & cmnDevID != 0 {
                deviceID = field.loadUnaligned(as: Int32.self)   // dev_t
                field = field.advanced(by: MemoryLayout<Int32>.size)
            }
            if returned.commonattr & cmnObjType != 0 {
                objType = field.loadUnaligned(as: UInt32.self)
                field = field.advanced(by: MemoryLayout<UInt32>.size)
            }
            if returned.commonattr & cmnModTime != 0 {
                let ts = field.loadUnaligned(as: timespec.self)
                mtime = Int64(ts.tv_sec)
                field = field.advanced(by: MemoryLayout<timespec>.size)
            }
            if returned.commonattr & cmnFileID != 0 {
                inode = field.loadUnaligned(as: UInt64.self)
                field = field.advanced(by: MemoryLayout<UInt64>.size)
            }
            if returned.fileattr & fileAllocSize != 0 {
                allocSize = field.loadUnaligned(as: Int64.self)
                field = field.advanced(by: MemoryLayout<Int64>.size)
            }

            if name != "." && name != ".." {
                let isDir = objType == vtypeDir
                let isLink = objType == vtypeLink
                entries.append(DirEntry(
                    name: name,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    allocatedSize: isDir ? 0 : allocSize,
                    mtime: mtime,
                    deviceID: deviceID,
                    inode: inode
                ))
            }

            entry = entry.advanced(by: entryLength)
        }
    }
}
