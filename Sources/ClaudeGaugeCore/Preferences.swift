import Foundation

/// Menu-bar number preference (non-sensitive; persisted in UserDefaults).
public enum StatusDisplayMode: String, CaseIterable, Sendable, Equatable {
    case remaining = "remaining"
    case used = "used"

    public var settingsLabel: String {
        switch self {
        case .remaining:
            return "Remaining % (100% = untouched)"
        case .used:
            return "Used % (like /usage)"
        }
    }
}

/// How many windows the menu bar title shows.
public enum MenuBarLayout: String, CaseIterable, Sendable, Equatable {
    case compact = "compact"
    case full = "full"

    public var settingsLabel: String {
        switch self {
        case .compact:
            return "5-hour + tightest weekly"
        case .full:
            return "Every limit"
        }
    }
}

public enum AppPreferences {
    public static let displayModeKey = "statusDisplayMode"
    public static let menuBarLayoutKey = "menuBarLayout"
    public static let pollIntervalKey = "pollIntervalSeconds"
    public static let allowedPollIntervals: [TimeInterval] = [30, 60, 120, 300]
    public static let defaultPollInterval: TimeInterval = 60

    public static func displayMode(defaults: UserDefaults = .standard) -> StatusDisplayMode {
        if let raw = defaults.string(forKey: displayModeKey),
           let mode = StatusDisplayMode(rawValue: raw)
        {
            return mode
        }
        return .remaining
    }

    public static func setDisplayMode(_ mode: StatusDisplayMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: displayModeKey)
    }

    public static func menuBarLayout(defaults: UserDefaults = .standard) -> MenuBarLayout {
        if let raw = defaults.string(forKey: menuBarLayoutKey),
           let layout = MenuBarLayout(rawValue: raw)
        {
            return layout
        }
        return .compact
    }

    public static func setMenuBarLayout(_ layout: MenuBarLayout, defaults: UserDefaults = .standard) {
        defaults.set(layout.rawValue, forKey: menuBarLayoutKey)
    }

    public static func pollInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.double(forKey: pollIntervalKey)
        if allowedPollIntervals.contains(stored) {
            return stored
        }
        return defaultPollInterval
    }

    public static func setPollInterval(_ interval: TimeInterval, defaults: UserDefaults = .standard) {
        let clamped = allowedPollIntervals.contains(interval) ? interval : defaultPollInterval
        defaults.set(clamped, forKey: pollIntervalKey)
    }

    public static func formatPollInterval(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return "\(Int(interval)) s"
        }
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}
