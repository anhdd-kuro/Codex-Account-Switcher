import AppKit
import Foundation

/// Number, money and date formatting for the Analytics tab (tmp/analytics-spec.md §4.7, §5.3, §6).
enum AnalyticsPanelFormat {
    /// K, M, B, T with one decimal, rolling over at 1000.
    static func compact(_ value: Int) -> String {
        let magnitude = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        guard magnitude >= 1000 else { return "\(value)" }
        let units = ["K", "M", "B", "T"]
        var scaled = magnitude / 1000
        var index = 0
        while index < units.count - 1, (scaled * 10).rounded() / 10 >= 1000 {
            scaled /= 1000
            index += 1
        }
        return sign + String(format: "%.1f", scaled) + units[index]
    }

    static func grouped(_ value: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// `x < 1` → 4 decimals, otherwise 2 (§5.3).
    static func usd(_ value: Double) -> String {
        let formatter = value < 1 ? smallUSD : largeUSD
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// Headline estimate: "≈ $X", "≥ $X" when some model had no price, "Unpriced" when nothing was priced (§6).
    static func estimatedCost(_ value: Double, isPartial: Bool) -> String {
        if isPartial && value <= 0 { return "Unpriced" }
        return (isPartial ? "≥ " : "≈ ") + usd(value)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func share(_ value: Double) -> String {
        if value > 0 && value < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", value)
    }

    static func bytes(processed: Int64, total: Int64) -> String {
        let gigabyte = 1_000_000_000.0
        let megabyte = 1_000_000.0
        let unit = Double(total) >= gigabyte ? gigabyte : megabyte
        let suffix = unit == gigabyte ? "GB" : "MB"
        let totalValue = Double(total) / unit
        let totalText = totalValue >= 10 ? String(format: "%.0f", totalValue) : String(format: "%.1f", totalValue)
        return String(format: "%.1f", Double(processed) / unit) + " / " + totalText + " " + suffix
    }

    static func day(_ date: Date) -> String { shortDay.string(from: date) }
    static func dayWithYear(_ date: Date) -> String { longDay.string(from: date) }
    static func month(_ date: Date) -> String { monthYear.string(from: date) }
    static func monthName(_ date: Date) -> String { monthOnly.string(from: date) }
    static func hour(_ date: Date) -> String { hourMinute.string(from: date) }
    static func weekdayDay(_ date: Date) -> String { weekdayShort.string(from: date) }

    /// "Oct 1 — Oct 31", with years only when the range leaves the current year.
    static func range(from: Date, to: Date) -> String {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())
        let needsYear = calendar.component(.year, from: from) != thisYear || calendar.component(.year, from: to) != thisYear
        let format: (Date) -> String = needsYear ? dayWithYear : day
        if calendar.isDate(from, inSameDayAs: to) { return format(from) }
        return "\(format(from)) — \(format(to))"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static let shortDay = formatter("MMM d")
    private static let longDay = formatter("MMM d, yyyy")
    private static let monthYear = formatter("MMM yyyy")
    private static let monthOnly = formatter("MMM")
    private static let hourMinute = formatter("HH:mm")
    private static let weekdayShort = formatter("EEE, MMM d")

    private static let groupedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func currency(decimals: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter
    }

    private static let smallUSD = currency(decimals: 4)
    private static let largeUSD = currency(decimals: 2)
}

/// Colours for the Analytics charts (§4.2, §4.5).
enum AnalyticsPanelPalette {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static let fallback: [UInt32] = [
        0xE879F9, 0x8B5CF6, 0xEC4899, 0x14B8A6, 0x78716C, 0x06B6D4,
        0x84CC16, 0xA855F7, 0xEF4444, 0xEAB308, 0x6366F1, 0x22C55E
    ]

    /// Matched by substring; anything else hashes stably into a 12-colour list.
    static func modelColor(_ model: String) -> NSColor {
        let name = model.lowercased()
        if name.contains("codex") { return rgb(0x3B82F6) }
        if name.contains("gpt") || name.contains("openai") { return rgb(0x10B981) }
        if name.contains("claude") || name.contains("anthropic") { return rgb(0xD97757) }
        if name.contains("gemini") || name.contains("google") { return rgb(0x2196F3) }
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = (hash &* 33) ^ UInt32(byte) }
        return rgb(fallback[Int(hash % UInt32(fallback.count))])
    }

    /// Legend label: the colour family for matched names, otherwise the model itself.
    static func modelFamily(_ model: String) -> String {
        let name = model.lowercased()
        if name.contains("codex") { return "Codex" }
        if name.contains("gpt") || name.contains("openai") { return "GPT" }
        if name.contains("claude") || name.contains("anthropic") { return "Claude" }
        if name.contains("gemini") || name.contains("google") { return "Gemini" }
        return model
    }

    /// Five heatmap levels; level 0 sits on the tile as an empty well.
    static func heatLevels(_ theme: PanelTheme) -> [NSColor] {
        theme.isDark
            ? [theme.trackFill, rgb(0x065F46), rgb(0x059669), rgb(0x10B981), rgb(0x34D399)]
            : [rgb(0xEBEDF0), rgb(0xA7F3D0), rgb(0x6EE7B7), rgb(0x34D399), rgb(0x10B981)]
    }

    static func sourceColor(_ source: AnalyticsSource, theme: PanelTheme) -> NSColor {
        switch source {
        case .codex: return theme.isDark ? .white.withAlphaComponent(0.88) : theme.primaryText
        case .claude: return MenuBarGlyph.claudeOrange
        }
    }
}
