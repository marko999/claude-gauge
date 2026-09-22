import Foundation

/// Which plan limit a window describes.
public enum UsageWindowKind: String, Equatable, Sendable {
    case session
    case weeklyAll
    case weeklyScoped
    case other
}

/// One rate-limit window as reported by the Claude OAuth usage endpoint.
public struct UsageWindow: Equatable, Sendable {
    public var id: String
    public var kind: UsageWindowKind
    /// Long label for the popover, e.g. "Weekly · Fable".
    public var label: String
    /// Compact label for the menu bar, e.g. "W·Fable".
    public var shortLabel: String
    /// 0–100, as reported.
    public var percentUsed: Double
    public var resetsAt: Date?
    public var isActive: Bool

    public init(
        id: String,
        kind: UsageWindowKind,
        label: String,
        shortLabel: String,
        percentUsed: Double,
        resetsAt: Date? = nil,
        isActive: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.shortLabel = shortLabel
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.isActive = isActive
    }

    public var percentRemaining: Double {
        max(0, min(100, 100 - percentUsed))
    }

    public var isWeekly: Bool {
        kind == .weeklyAll || kind == .weeklyScoped
    }
}

/// Pay-as-you-go credits that kick in after plan limits (only shown when enabled).
public struct ExtraUsage: Equatable, Sendable {
    public var isEnabled: Bool
    public var usedMinor: Double?
    public var limitMinor: Double?
    public var exponent: Int
    public var currency: String
    public var percentUsed: Double?

    public init(
        isEnabled: Bool,
        usedMinor: Double? = nil,
        limitMinor: Double? = nil,
        exponent: Int = 2,
        currency: String = "USD",
        percentUsed: Double? = nil
    ) {
        self.isEnabled = isEnabled
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.exponent = exponent
        self.currency = currency
        self.percentUsed = percentUsed
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var windows: [UsageWindow]
    public var extraUsage: ExtraUsage?

    public init(windows: [UsageWindow], extraUsage: ExtraUsage? = nil) {
        self.windows = windows
        self.extraUsage = extraUsage
    }

    public var session: UsageWindow? {
        windows.first { $0.kind == .session }
    }

    public var weeklyWindows: [UsageWindow] {
        windows.filter { $0.isWeekly }
    }

    /// The weekly window with the least headroom — the one that will bite first.
    public var tightestWeekly: UsageWindow? {
        weeklyWindows.min { $0.percentRemaining < $1.percentRemaining }
    }
}

// MARK: - JSON helpers

func asRecord(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func asDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let double = value as? Double {
        return double
    }
    if let int = value as? Int {
        return Double(int)
    }
    if let string = value as? String, let parsed = Double(string) {
        return parsed
    }
    return nil
}

func asBool(_ value: Any?) -> Bool? {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    return nil
}

/// Tolerant ISO-8601 parser: the API emits microsecond fractions, which
/// `ISO8601DateFormatter` rejects, so we trim to milliseconds on fallback.
public func parseISO8601Date(_ value: Any?) -> Date? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: string) {
        return date
    }
    if let range = string.range(of: #"\.\d+"#, options: .regularExpression) {
        let digits = string[range].dropFirst()
        let trimmed = string.replacingCharacters(in: range, with: "." + digits.prefix(3))
        if let date = fractional.date(from: trimmed) {
            return date
        }
    }
    return nil
}

// MARK: - Usage response parsing

private func windowKind(fromLimitKind kind: String) -> UsageWindowKind {
    switch kind.lowercased() {
    case "session":
        return .session
    case "weekly_all":
        return .weeklyAll
    case "weekly_scoped":
        return .weeklyScoped
    default:
        return .other
    }
}

private func humanize(_ raw: String) -> String {
    raw.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
}

private func parseLimitEntry(_ entry: [String: Any], index: Int) -> UsageWindow? {
    guard let rawKind = entry["kind"] as? String,
          let percent = asDouble(entry["percent"])
    else {
        return nil
    }
    let kind = windowKind(fromLimitKind: rawKind)

    var scopeName: String?
    if let scope = asRecord(entry["scope"]) {
        if let model = asRecord(scope["model"]),
           let name = model["display_name"] as? String, !name.isEmpty
        {
            scopeName = name
        } else if let surface = scope["surface"] as? String, !surface.isEmpty {
            scopeName = surface
        }
    }

    let label: String
    let shortLabel: String
    var id = rawKind.lowercased()
    switch kind {
    case .session:
        label = "5-hour session"
        shortLabel = "5h"
    case .weeklyAll:
        label = "Weekly · all models"
        shortLabel = "W"
    case .weeklyScoped:
        let name = scopeName ?? "scoped"
        label = "Weekly · \(name)"
        shortLabel = "W·\(name)"
        id += ":" + name.lowercased()
    case .other:
        let name = scopeName.map { " · \($0)" } ?? ""
        label = humanize(rawKind) + name
        shortLabel = humanize(rawKind)
        id += ":\(index)"
    }

    return UsageWindow(
        id: id,
        kind: kind,
        label: label,
        shortLabel: shortLabel,
        percentUsed: max(0, min(100, percent)),
        resetsAt: parseISO8601Date(entry["resets_at"]),
        isActive: asBool(entry["is_active"]) ?? false
    )
}

private func parseLegacyWindow(
    _ record: Any?,
    id: String,
    kind: UsageWindowKind,
    label: String,
    shortLabel: String
) -> UsageWindow? {
    guard let record = asRecord(record),
          let utilization = asDouble(record["utilization"])
    else {
        return nil
    }
    return UsageWindow(
        id: id,
        kind: kind,
        label: label,
        shortLabel: shortLabel,
        percentUsed: max(0, min(100, utilization)),
        resetsAt: parseISO8601Date(record["resets_at"]),
        isActive: false
    )
}

private func parseExtraUsage(_ root: [String: Any]) -> ExtraUsage? {
    if let spend = asRecord(root["spend"]) {
        let used = asRecord(spend["used"])
        let limit = asRecord(spend["limit"])
        let currency = (used?["currency"] as? String) ?? (limit?["currency"] as? String) ?? "USD"
        let exponent = Int(asDouble(used?["exponent"]) ?? asDouble(limit?["exponent"]) ?? 2)
        return ExtraUsage(
            isEnabled: asBool(spend["enabled"]) ?? false,
            usedMinor: asDouble(used?["amount_minor"]),
            limitMinor: asDouble(limit?["amount_minor"]),
            exponent: exponent,
            currency: currency,
            percentUsed: asDouble(spend["percent"])
        )
    }
    if let extra = asRecord(root["extra_usage"]) {
        return ExtraUsage(
            isEnabled: asBool(extra["is_enabled"]) ?? false,
            usedMinor: asDouble(extra["used_credits"]),
            limitMinor: asDouble(extra["monthly_limit"]),
            exponent: Int(asDouble(extra["decimal_places"]) ?? 2),
            currency: (extra["currency"] as? String) ?? "USD",
            percentUsed: asDouble(extra["utilization"])
        )
    }
    return nil
}

/// Parse `GET /api/oauth/usage`. Prefers the structured `limits[]` list (what the
/// desktop app renders) and falls back to the older top-level window fields.
public func parseUsageResponse(_ json: Any?) -> UsageSnapshot? {
    guard let root = asRecord(json) else { return nil }

    var windows: [UsageWindow] = []
    if let limits = root["limits"] as? [[String: Any]] {
        for (index, entry) in limits.enumerated() {
            if let window = parseLimitEntry(entry, index: index) {
                windows.append(window)
            }
        }
    }

    if windows.isEmpty {
        if let session = parseLegacyWindow(
            root["five_hour"], id: "session", kind: .session,
            label: "5-hour session", shortLabel: "5h"
        ) {
            windows.append(session)
        }
        if let weekly = parseLegacyWindow(
            root["seven_day"], id: "weekly_all", kind: .weeklyAll,
            label: "Weekly · all models", shortLabel: "W"
        ) {
            windows.append(weekly)
        }
        let scoped: [(key: String, name: String)] = [
            ("seven_day_opus", "Opus"),
            ("seven_day_sonnet", "Sonnet"),
            ("seven_day_cowork", "Cowork"),
            ("seven_day_oauth_apps", "OAuth apps"),
        ]
        for item in scoped {
            if let window = parseLegacyWindow(
                root[item.key], id: "weekly_scoped:\(item.name.lowercased())",
                kind: .weeklyScoped, label: "Weekly · \(item.name)", shortLabel: "W·\(item.name)"
            ) {
                windows.append(window)
            }
        }
    }

    guard !windows.isEmpty else { return nil }
    return UsageSnapshot(windows: windows, extraUsage: parseExtraUsage(root))
}
