import AppKit

/// Local-only file operations. There is intentionally no networking here or
/// anywhere else in the app.
enum FileActions {
    /// Opens Finder with the item selected.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Moves the item to the Trash (reversible). Never deletes in place.
    /// - Returns: the resulting URL inside the Trash, if available.
    @discardableResult
    static func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}
