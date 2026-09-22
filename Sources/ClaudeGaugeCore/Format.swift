import Foundation

public enum UsageSeverity: Int, Equatable, Comparable, Sendable {
    case normal = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public func severity(forRemainingPercent remaining: Double) -> UsageSeverity {
    if remaining <= 10 {
        return .critical
    }
    if remaining <= 25 {
        return .warning
    }
    return .normal
}

public func severity(of window: UsageWindow) -> UsageSeverity {
    severity(forRemainingPercent: window.percentRemaining)
}

public func severity(of snapshot: UsageSnapshot) -> UsageSeverity {
    snapshot.windows.map(severity(of:)).max() ?? .normal
}

public func formatPercent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

public func displayedPercent(_ window: UsageWindow, mode: StatusDisplayMode) -> Double {
    mode == .remaining ? window.percentRemaining : window.percentUsed
}

public func displayedSuffix(mode: StatusDisplayMode) -> String {
    mode == .remaining ? "left" : "used"
}

/// Windows shown in the menu bar title. Compact = session + the tightest weekly.
public func menuBarWindows(_ snapshot: UsageSnapshot, layout: MenuBarLayout) -> [UsageWindow] {
    let ordered = orderedWindows(snapshot)
    switch layout {
    case .full:
        return ordered
    case .compact:
        let picked = [snapshot.session, snapshot.tightestWeekly].compactMap { $0 }
        return picked.isEmpty ? ordered : picked
    }
}

/// Session first, then weekly (all models before scoped), then anything else.
public func orderedWindows(_ snapshot: UsageSnapshot) -> [UsageWindow] {
    func rank(_ window: UsageWindow) -> Int {
        switch window.kind {
        case .session: return 0
        case .weeklyAll: return 1
        case .weeklyScoped: return 2
        case .other: return 3
        }
    }
    return snapshot.windows.enumerated()
        .sorted { lhs, rhs in
            let l = rank(lhs.element)
            let r = rank(rhs.element)
            return l == r ? lhs.offset < rhs.offset : l < r
        }
        .map { $0.element }
}

public func formatStatusText(
    _ snapshot: UsageSnapshot,
    mode: StatusDisplayMode,
    layout: MenuBarLayout
) -> String {
    menuBarWindows(snapshot, layout: layout)
        .map { "\($0.shortLabel) \(formatPercent(displayedPercent($0, mode: mode)))" }
        .joined(separator: " · ")
}

public func formatResetsIn(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "—" }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 {
        return "now"
    }
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    let days = hours / 24
    if days >= 1 {
        return "\(days)d \(hours % 24)h"
    }
    if hours >= 1 {
        return "\(hours)h \(minutes % 60)m"
    }
    return "\(max(1, minutes))m"
}

public func formatResetsAbsolute(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateFormat = "EEE HH:mm"
    return formatter.string(from: date)
}

public func formatWindowLine(
    _ window: UsageWindow,
    mode: StatusDisplayMode,
    now: Date = Date()
) -> String {
    let value = formatPercent(displayedPercent(window, mode: mode))
    return "\(window.label): \(value) \(displayedSuffix(mode: mode)) · resets in \(formatResetsIn(window.resetsAt, now: now))"
}

public func formatTooltip(
    _ snapshot: UsageSnapshot,
    mode: StatusDisplayMode,
    lastUpdated: Date,
    now: Date = Date(),
    locale: Locale = .current
) -> String {
    var lines = orderedWindows(snapshot).map { formatWindowLine($0, mode: mode, now: now) }
    if let extra = snapshot.extraUsage, extra.isEnabled {
        lines.append("Extra usage: \(formatExtraUsage(extra, locale: locale))")
    }
    lines.append(formatUpdatedLabel(lastUpdated, now: now))
    return lines.joined(separator: "\n")
}

public func formatMinorAmount(
    _ minor: Double,
    exponent: Int,
    currency: String,
    locale: Locale = .current
) -> String {
    let divisor = pow(10.0, Double(max(0, exponent)))
    let major = minor / divisor
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.maximumFractionDigits = exponent
    formatter.minimumFractionDigits = exponent > 0 ? 2 : 0
    return formatter.string(from: NSNumber(value: major)) ?? String(format: "%.2f %@", major, currency)
}

public func formatExtraUsage(_ extra: ExtraUsage, locale: Locale = .current) -> String {
    let used = extra.usedMinor.map {
        formatMinorAmount($0, exponent: extra.exponent, currency: extra.currency, locale: locale)
    } ?? "—"
    let limit = extra.limitMinor.map {
        formatMinorAmount($0, exponent: extra.exponent, currency: extra.currency, locale: locale)
    }
    var text = used
    if let limit {
        text += " of \(limit)"
    }
    if let percent = extra.percentUsed {
        text += " (\(formatPercent(percent)) used)"
    }
    return text
}

public func formatUpdatedLabel(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 {
        return "Updated just now"
    }
    let minutes = Int(seconds / 60)
    if minutes < 60 {
        return "Updated \(minutes)m ago"
    }
    let hours = minutes / 60
    if hours < 24 {
        return "Updated \(hours)h ago"
    }
    return "Updated \(hours / 24)d ago"
}

public func formatLoadingStatus() -> String {
    "Claude …"
}

public func formatErrorStatus() -> String {
    "Claude ⚠︎"
}

// MARK: - Launch at Login copy

public enum LaunchAtLoginDisplayState: String, Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

public func formatLaunchAtLoginStatus(_ state: LaunchAtLoginDisplayState) -> String {
    switch state {
    case .enabled:
        return "Registered — opens at login"
    case .notRegistered:
        return "Not registered"
    case .requiresApproval:
        return "Needs approval in System Settings → General → Login Items"
    case .notFound:
        return "Not available for this bundle"
    case .unknown:
        return "Status unknown"
    }
}

public func formatLaunchAtLoginLimitation(isInApplications: Bool) -> String {
    if isInApplications {
        return "Registered via SMAppService."
    }
    return "Move ClaudeGauge.app to /Applications for reliable Launch at Login (local build runs from dist/)."
}
