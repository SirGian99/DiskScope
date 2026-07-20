import Foundation

/// A single entry in the scanned filesystem tree.
///
/// `FileNode` is a reference type because the tree is large (potentially millions
/// of entries) and is mutated in place by the background scanner as sizes are
/// accumulated bottom-up. To keep memory down we do **not** store a full `URL`
/// per node; the path is reconstructed on demand by walking up to the root.
final class FileNode {
    let name: String
    let isDirectory: Bool
    weak var parent: FileNode?

    /// Only the root node carries an absolute URL; descendants derive theirs.
    private let rootURL: URL?

    /// Total on-disk (allocated) bytes of this node and everything beneath it.
    /// Mutated by the scanner under `ScanCoordinator`'s lock.
    var size: Int64 = 0

    /// Children of a directory. Empty for files. Mutated under the scanner lock.
    var children: [FileNode] = []

    /// True once this node's entire subtree has been measured.
    var scanned: Bool = false

    /// True if the directory could not be read (e.g. permission denied).
    var inaccessible: Bool = false

    /// Directory modification time (seconds since 1970). Captured cheaply during
    /// the scan and used to validate a cached tree on a per-directory basis: if
    /// a folder's live mtime differs from this, its child listing is stale.
    var mtime: Int64 = 0

    /// Number of child directories still being measured. Used by the parallel
    /// scanner to know when a directory's subtree total is final (reaches 0).
    /// Mutated only under the scanner lock.
    var pendingSubdirs: Int = 0

    /// Filesystem identity, used to avoid counting the same directory twice when
    /// it is reachable through more than one path (APFS firmlinks, bind mounts,
    /// hardlinked directories). Aliases share the same `(deviceID, inode)`.
    var deviceID: Int32 = 0
    var inode: UInt64 = 0

    init(name: String, isDirectory: Bool, parent: FileNode?, rootURL: URL? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
        self.rootURL = rootURL
    }

    /// Reconstructs the absolute file URL by walking up the parent chain.
    var url: URL {
        if let rootURL { return rootURL }
        if let parent { return parent.url.appendingPathComponent(name) }
        return URL(fileURLWithPath: "/" + name)
    }
}

extension FileNode: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension FileNode: Hashable {
    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
