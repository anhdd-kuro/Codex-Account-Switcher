import AppKit
import Foundation

struct CodexAccount: Equatable {
    let selector: String
    let email: String
    let plan: String
    let fiveHourUsage: String
    let weeklyUsage: String
    let fiveHourUsedPercent: Int?
    let weeklyUsedPercent: Int?
    let lastActivity: String
    let isActive: Bool
}

struct HealthStatus {
    let title: String
    let value: String
    let color: NSColor
}

struct SwitchHistoryEntry: Codable {
    let date: Date
    let fromLabel: String
    let toLabel: String
    let automatic: Bool
    let reason: String
    let result: String
}

struct ResetHistoryEntry: Codable {
    let date: Date
    let accountLabel: String
    let result: String
    let creditBefore: Int?
    let creditAfter: Int?
    let fiveHourRemaining: Int?
    let weeklyRemaining: Int?
    let detail: String
}

enum RouteBCapabilityState {
    case ready
    case testRequired
    case blocked
}

struct RouteBCapability {
    let label: String
    let state: RouteBCapabilityState
}

struct RouteBProviderProfile {
    let id: String
    let name: String
    let provider: String
    let model: String
    let summary: String
    let capabilities: [RouteBCapability]
}

let routeBProviderProfiles = [
    RouteBProviderProfile(
        id: "openrouter-text-helper",
        name: "Text Helper",
        provider: "OpenRouter",
        model: "z-ai/glm-5.2",
        summary: "Low-risk drafting, summaries, and read-only checks.",
        capabilities: [
            RouteBCapability(label: "Chat ready", state: .ready),
            RouteBCapability(label: "MCP test required", state: .testRequired),
            RouteBCapability(label: "Browser test required", state: .testRequired),
            RouteBCapability(label: "Live ops blocked", state: .blocked)
        ]
    ),
    RouteBProviderProfile(
        id: "openrouter-visual-helper",
        name: "Visual Helper",
        provider: "OpenRouter",
        model: "z-ai/glm-5v-turbo",
        summary: "Image review and visual context; no account actions.",
        capabilities: [
            RouteBCapability(label: "Chat ready", state: .ready),
            RouteBCapability(label: "Vision ready", state: .ready),
            RouteBCapability(label: "MCP blocked", state: .blocked),
            RouteBCapability(label: "Live ops blocked", state: .blocked)
        ]
    )
]

struct ResetCredit: Equatable {
    let id: String
    let title: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
}

struct ResetCreditsSnapshot: Equatable {
    let availableCount: Int?
    let credits: [ResetCredit]
    let lastUpdatedText: String
    let lastError: String?

    var availableCredits: [ResetCredit] {
        credits.filter { $0.status.lowercased() == "available" }
    }

    var displayCount: Int? {
        availableCount ?? (credits.isEmpty ? nil : availableCredits.count)
    }
}

struct UsageLimitWindowSnapshot: Equatable {
    let remainingPercent: Int
    let resetAt: Date?
}

struct DirectUsageSnapshot: Equatable {
    let fiveHour: UsageLimitWindowSnapshot
    let weekly: UsageLimitWindowSnapshot
}

struct ResetConsumeReceipt {
    let code: String
    let windowsReset: Int
    let message: String
}

struct ResetVerificationOutcome {
    let resetSnapshot: ResetCreditsSnapshot?
    let usageSnapshot: DirectUsageSnapshot?
    let creditConfirmed: Bool
    let usageConfirmed: Bool
    let attempts: Int
    let detail: String
}

enum UsageDisplayMode: String {
    case fiveHour
    case weekly
}

enum ToolbarDisplayStyle: String {
    case detailed
    case compact
}

enum AutoSwitchMode: String {
    case off
    case ask
    case threshold
    case zero
}

enum AutoResumeMode: String {
    case off
    case ask
    case idle5
    case idle10
    case always
}

enum AccountPanelMode {
    case usage
    case settings
    case routeB
    case resets
}

enum SettingsPanelAction: String {
    case usageView
    case addClaudeAccount
    case settingsView
    case routeBView
    case resetCreditsView
    case addAccount
    case addDeviceAccount
    case editLabels
    case removeAccount
    case usageWeekly
    case usageFiveHour
    case styleDetailed
    case styleCompact
    case toggleLaunchAtLogin
    case toggleUsageReminder
    case editUsageReminder
    case toggleAutoSwitch
    case editAutoSwitch
    case editAutoResume
    case toggleConfirmSwitch
    case toggleProtectCodex
    case editRefresh
    case forceRefresh
    case checkUpdates
    case cleanBackups
    case diagnostics
    case quit
}

func usageStatusColor(for percent: Int?) -> NSColor {
    guard let percent else { return .secondaryLabelColor }
    return PanelTheme.current(for: nil).color(PanelTheme.usageTone(for: percent))
}

extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

struct PanelTheme {
    let isDark: Bool

    enum Tone {
        case green
        case orange
        case red
        case blue
        case indigo
        case neutral
    }

    static func current(for appearance: NSAppearance?) -> PanelTheme {
        PanelTheme(isDark: appearance?.isDarkMode ?? NSApp.effectiveAppearance.isDarkMode)
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    // Vitesse palette (antfu/vitesse-theme): flat surfaces, warm text, green accent.
    // Text
    var primaryText: NSColor { isDark ? Self.rgb(0xCECABE) : Self.rgb(0x393A34) }
    var secondaryText: NSColor { isDark ? Self.rgb(0x888888) : Self.rgb(0x6F6F68) }
    var tertiaryText: NSColor { isDark ? Self.rgb(0x888888, 0.72) : Self.rgb(0x393A34, 0.45) }

    // Surface
    var panelTint: NSColor { isDark ? Self.rgb(0x121212) : Self.rgb(0xFFFFFF) }
    var panelEdge: NSColor { isDark ? Self.rgb(0xFFFFFF, 0.10) : Self.rgb(0x000000, 0.12) }
    var panelHighlight: NSColor { isDark ? NSColor.white : NSColor.white }

    // Tiles, hairlines and controls
    var tileFill: NSColor { isDark ? Self.rgb(0x1E1E1E) : Self.rgb(0xF7F7F7) }
    var tileHoverFill: NSColor { isDark ? Self.rgb(0x262626) : Self.rgb(0xEEEEEE) }
    var tileBorder: NSColor { isDark ? Self.rgb(0xFFFFFF, 0.06) : Self.rgb(0x000000, 0.06) }
    var hairline: NSColor { isDark ? Self.rgb(0xFFFFFF, 0.08) : Self.rgb(0x000000, 0.08) }
    var controlFill: NSColor { isDark ? Self.rgb(0x262626) : Self.rgb(0xEEEEEE) }
    var controlHoverFill: NSColor { isDark ? Self.rgb(0x303030) : Self.rgb(0xE4E4E4) }
    var controlBorder: NSColor { isDark ? Self.rgb(0xFFFFFF, 0.08) : Self.rgb(0x000000, 0.06) }
    var segmentTrack: NSColor { isDark ? Self.rgb(0x1E1E1E) : Self.rgb(0xF2F2F2) }
    var segmentSelected: NSColor { isDark ? Self.rgb(0x2C2C2C) : Self.rgb(0xFFFFFF) }
    var segmentSelectedBorder: NSColor { isDark ? Self.rgb(0xFFFFFF, 0.08) : Self.rgb(0x000000, 0.08) }
    var trackFill: NSColor { isDark ? Self.rgb(0xFFFFFF, 0.08) : Self.rgb(0x000000, 0.07) }
    var switchOff: NSColor { isDark ? Self.rgb(0xFFFFFF, 0.18) : Self.rgb(0x000000, 0.14) }
    var accent: NSColor { isDark ? Self.rgb(0x4D9375) : Self.rgb(0x1C6B48) }

    // Semantic colours: `color` for graphics, `text` for readable text
    var blueText: NSColor { text(.blue) }

    func color(_ tone: Tone) -> NSColor {
        switch tone {
        case .green: return isDark ? Self.rgb(0x4D9375) : Self.rgb(0x1C6B48)
        case .orange: return isDark ? Self.rgb(0xE6CC77) : Self.rgb(0xBDA437)
        case .red: return isDark ? Self.rgb(0xCB7676) : Self.rgb(0xAB5959)
        case .blue: return isDark ? Self.rgb(0x6394BF) : Self.rgb(0x296AA3)
        case .indigo: return isDark ? Self.rgb(0xA08CC8) : Self.rgb(0x7E5FB0)
        case .neutral: return secondaryText
        }
    }

    func text(_ tone: Tone) -> NSColor {
        switch tone {
        case .green: return isDark ? Self.rgb(0x5DA994) : Self.rgb(0x1C6B48)
        case .orange: return isDark ? Self.rgb(0xE6CC77) : Self.rgb(0x8C7A26)
        case .red: return isDark ? Self.rgb(0xCB7676) : Self.rgb(0xAB5959)
        case .blue: return isDark ? Self.rgb(0x6394BF) : Self.rgb(0x296AA3)
        case .indigo: return isDark ? Self.rgb(0xA08CC8) : Self.rgb(0x7E5FB0)
        case .neutral: return primaryText
        }
    }

    func tint(_ tone: Tone) -> NSColor {
        if tone == .neutral { return controlFill }
        return color(tone).withAlphaComponent(isDark ? 0.20 : 0.14)
    }

    static func usageTone(for percent: Int?) -> Tone {
        guard let percent else { return .neutral }
        if percent >= 50 { return .green }
        if percent >= 20 { return .orange }
        return .red
    }
}

enum ResetCreditsFetchResult {
    case success(ResetCreditsSnapshot)
    case failure(String)
}

enum ResetCreditRedemptionResult {
    case success(ResetConsumeReceipt)
    case failure(String)
}

enum DirectUsageFetchResult {
    case success(DirectUsageSnapshot)
    case failure(String)
}

struct SavedAccountAuth {
    let email: String
    let accessToken: String
    let accountID: String
}

enum SavedAccountAuthResult {
    case success(SavedAccountAuth)
    case failure(String)
}
