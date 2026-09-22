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

/// Which weekly windows the menu bar shows.
public enum WeeklySelection: String, CaseIterable, Sendable, Equatable {
    case none = "none"
    case tightest = "tightest"
    case all = "all"

    public var settingsLabel: String {
        switch self {
        case .none:
            return "No weekly limit"
        case .tightest:
            return "Tightest weekly limit only"
        case .all:
            return "Every weekly limit"
        }
    }
}

/// What the menu bar title is made of.
public struct MenuBarSelection: Equatable, Sendable {
    public var showSession: Bool
    public var weekly: WeeklySelection

    public init(showSession: Bool = true, weekly: WeeklySelection = .tightest) {
        self.showSession = showSession
        self.weekly = weekly
    }

    public static let `default` = MenuBarSelection()
}

/// How the menu bar title is drawn.
public enum MenuBarStyle: String, CaseIterable, Sendable, Equatable {
    case text = "text"
    case bar = "bar"
    case barAndText = "barAndText"

    public var settingsLabel: String {
        switch self {
        case .text:
            return "Text  (5h 94% · W 97%)"
        case .bar:
            return "Progress bars"
        case .barAndText:
            return "Progress bars + %"
        }
    }
}

public enum AppPreferences {
    public static let displayModeKey = "statusDisplayMode"
    public static let showSessionKey = "menuBarShowSession"
    public static let weeklySelectionKey = "menuBarWeekly"
    public static let menuBarStyleKey = "menuBarStyle"
    /// v0.1 key (`compact` / `full`); read once for migration.
    public static let legacyLayoutKey = "menuBarLayout"
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

    public static func menuBarSelection(defaults: UserDefaults = .standard) -> MenuBarSelection {
        var selection = MenuBarSelection.default
        if defaults.object(forKey: showSessionKey) != nil {
            selection.showSession = defaults.bool(forKey: showSessionKey)
        }
        if let raw = defaults.string(forKey: weeklySelectionKey),
           let weekly = WeeklySelection(rawValue: raw)
        {
            selection.weekly = weekly
        } else if defaults.string(forKey: legacyLayoutKey) == "full" {
            selection.weekly = .all
        }
        return selection
    }

    public static func setMenuBarSelection(_ selection: MenuBarSelection, defaults: UserDefaults = .standard) {
        defaults.set(selection.showSession, forKey: showSessionKey)
        defaults.set(selection.weekly.rawValue, forKey: weeklySelectionKey)
    }

    public static func menuBarStyle(defaults: UserDefaults = .standard) -> MenuBarStyle {
        if let raw = defaults.string(forKey: menuBarStyleKey),
           let style = MenuBarStyle(rawValue: raw)
        {
            return style
        }
        return .text
    }

    public static func setMenuBarStyle(_ style: MenuBarStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: menuBarStyleKey)
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
