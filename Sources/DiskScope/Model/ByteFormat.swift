import SwiftUI

/// Human-readable byte formatting, matching the "74.3 GB" / "526.4 MB" /
/// "0 bytes" style of disk-usage tools.
enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false   // "0 bytes" instead of "Zero KB"
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

extension Color {
    /// "Heat" color for a size cell: dim gray for small entries fading to a
    /// bright teal for the largest. `fraction` is expected to be log-scaled
    /// 0...1 relative to the biggest sibling in the same column.
    static func sizeHeat(fraction: Double, selected: Bool) -> Color {
        if selected { return .white }
        let f = min(max(fraction, 0), 1)
        let dim = (r: 0.52, g: 0.54, b: 0.58)
        let hot = (r: 0.42, g: 0.86, b: 0.96)
        return Color(
            red: dim.r + (hot.r - dim.r) * f,
            green: dim.g + (hot.g - dim.g) * f,
            blue: dim.b + (hot.b - dim.b) * f
        )
    }
}

/// Centralized dark theme so the look stays consistent and easy to tweak.
enum Theme {
    static let windowBackground = Color(nsColor: NSColor(white: 0.12, alpha: 1))
    static let columnBackground = Color(nsColor: NSColor(white: 0.145, alpha: 1))
    static let barColor = Color(red: 0.42, green: 0.86, blue: 0.96)
    static let rowText = Color(white: 0.92)
}
