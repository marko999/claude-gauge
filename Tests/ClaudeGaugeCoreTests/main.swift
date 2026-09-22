import ClaudeGaugeCore
import Foundation

// Lightweight test runner for Command Line Tools (no XCTest framework).

private var failures = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    if !condition() {
        failures += 1
        fputs("FAIL \(file):\(line): \(message)\n", stderr)
    }
}

private func expectEqual<T: Equatable>(
    _ a: T,
    _ b: T,
    _ message: String = "",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    if a != b {
        failures += 1
        fputs("FAIL \(file):\(line): expected \(b), got \(a). \(message)\n", stderr)
    }
}

private func json(_ text: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8))
}

// MARK: - Fixture: structured `limits[]` (what the desktop app renders)

private let structuredFixture = """
{
  "five_hour": {"utilization": 4.0, "resets_at": "2026-09-22T14:09:59.524164+00:00"},
  "seven_day": {"utilization": 1.0, "resets_at": "2026-09-24T13:59:59.524193+00:00"},
  "seven_day_opus": null,
  "nimbus_quill": {"utilization": 0.0, "resets_at": null},
  "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null},
  "limits": [
    {"kind": "session", "group": "session", "percent": 4, "severity": "normal",
     "resets_at": "2026-09-22T14:09:59.524164+00:00", "scope": null, "is_active": true},
    {"kind": "weekly_all", "group": "weekly", "percent": 1, "severity": "normal",
     "resets_at": "2026-09-24T13:59:59.524193+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 17, "severity": "normal",
     "resets_at": "2026-09-24T13:59:59.524419+00:00",
     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
  ],
  "spend": {
    "used": {"amount_minor": 1250, "currency": "USD", "exponent": 2},
    "limit": {"amount_minor": 10000, "currency": "USD", "exponent": 2},
    "percent": 12.5, "severity": "normal", "enabled": true
  }
}
"""

do {
    guard let snapshot = parseUsageResponse(json(structuredFixture)) else {
        failures += 1
        fputs("FAIL: structured fixture did not parse\n", stderr)
        exit(1)
    }
    expectEqual(snapshot.windows.count, 3, "three limits")
    expectEqual(snapshot.session?.percentUsed, 4, "session percent")
    expectEqual(snapshot.session?.isActive, true, "session active")
    expectEqual(snapshot.session?.shortLabel, "5h")
    expectEqual(snapshot.weeklyWindows.count, 2, "two weekly windows")
    expectEqual(snapshot.tightestWeekly?.label, "Weekly · Fable", "tightest weekly is the scoped one")
    expectEqual(snapshot.tightestWeekly?.shortLabel, "W·Fable")
    expectEqual(snapshot.tightestWeekly?.percentRemaining, 83)
    expect(snapshot.session?.resetsAt != nil, "session reset parsed (microsecond fraction)")
    if let reset = snapshot.session?.resetsAt {
        expectEqual(Int(reset.timeIntervalSince1970), 1_790_086_199, "reset epoch")
    }
    expectEqual(snapshot.extraUsage?.isEnabled, true, "spend enabled")
    expectEqual(snapshot.extraUsage?.usedMinor, 1250)
    expectEqual(snapshot.extraUsage?.limitMinor, 10000)
    expectEqual(snapshot.extraUsage?.percentUsed, 12.5)

    expectEqual(
        formatStatusText(snapshot, mode: .remaining, layout: .compact),
        "5h 96% · W·Fable 83%",
        "compact remaining"
    )
    expectEqual(
        formatStatusText(snapshot, mode: .used, layout: .compact),
        "5h 4% · W·Fable 17%",
        "compact used"
    )
    expectEqual(
        formatStatusText(snapshot, mode: .remaining, layout: .full),
        "5h 96% · W 99% · W·Fable 83%",
        "full remaining"
    )
    expectEqual(severity(of: snapshot), .normal, "no warning yet")

    let tooltip = formatTooltip(
        snapshot,
        mode: .remaining,
        lastUpdated: Date(timeIntervalSince1970: 1_790_068_000),
        now: Date(timeIntervalSince1970: 1_790_068_030),
        locale: Locale(identifier: "en_US")
    )
    expect(tooltip.contains("5-hour session: 96% left"), "tooltip session line")
    expect(tooltip.contains("Extra usage: $12.50 of $100.00 (13% used)"), "tooltip extra usage: \(tooltip)")
    expect(
        formatExtraUsage(snapshot.extraUsage!, locale: Locale(identifier: "de_DE")).contains("12,50"),
        "locale-aware currency"
    )
    expect(tooltip.contains("Updated just now"), "tooltip updated")
    expect(!tooltip.contains("sk-ant"), "no token in tooltip")
}

// MARK: - Fixture: legacy top-level windows only

private let legacyFixture = """
{
  "five_hour": {"utilization": 92.0, "resets_at": "2025-11-04T04:59:59.943648+00:00"},
  "seven_day": {"utilization": 35.0, "resets_at": "2025-11-06T03:59:59.943679+00:00"},
  "seven_day_oauth_apps": null,
  "seven_day_opus": {"utilization": 0.0, "resets_at": null},
  "iguana_necktie": null
}
"""

do {
    guard let snapshot = parseUsageResponse(json(legacyFixture)) else {
        failures += 1
        fputs("FAIL: legacy fixture did not parse\n", stderr)
        exit(1)
    }
    expectEqual(snapshot.windows.count, 3, "session + weekly + opus")
    expectEqual(snapshot.session?.percentRemaining, 8, "session nearly exhausted")
    expectEqual(severity(of: snapshot), .critical, "critical when ≤10% left")
    expectEqual(snapshot.tightestWeekly?.shortLabel, "W", "weekly_all tighter than opus at 0%")
    expectEqual(
        formatStatusText(snapshot, mode: .remaining, layout: .compact),
        "5h 8% · W 65%"
    )
    expect(snapshot.windows.last?.resetsAt == nil, "null resets_at tolerated")
    expectEqual(snapshot.extraUsage, nil, "no extra usage block")
}

// MARK: - Unrecognized payloads

expect(parseUsageResponse(nil) == nil, "nil payload")
expect(parseUsageResponse([:] as [String: Any]) == nil, "empty object")
expect(parseUsageResponse(["limits": []] as [String: Any]) == nil, "empty limits and no legacy fields")
expect(parseUsageResponse(json(#"{"type":"error","error":{"type":"authentication_error"}}"#)) == nil, "error body")

// MARK: - Dates

expect(parseISO8601Date("2026-09-22T14:09:59.524164+00:00") != nil, "6-digit fraction")
expect(parseISO8601Date("2026-09-22T14:09:59.524Z") != nil, "3-digit fraction")
expect(parseISO8601Date("2026-09-22T14:09:59Z") != nil, "no fraction")
expect(parseISO8601Date("") == nil, "empty")
expect(parseISO8601Date(NSNull()) == nil, "null")

// MARK: - Countdown formatting

do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    expectEqual(formatResetsIn(now.addingTimeInterval(4 * 3600 + 47 * 60 + 10), now: now), "4h 47m")
    expectEqual(formatResetsIn(now.addingTimeInterval(2 * 86400 + 4 * 3600 + 5), now: now), "2d 4h")
    expectEqual(formatResetsIn(now.addingTimeInterval(12 * 60), now: now), "12m")
    expectEqual(formatResetsIn(now.addingTimeInterval(20), now: now), "1m")
    expectEqual(formatResetsIn(now.addingTimeInterval(-5), now: now), "now")
    expectEqual(formatResetsIn(nil, now: now), "—")

    expectEqual(formatUpdatedLabel(now.addingTimeInterval(-10), now: now), "Updated just now")
    expectEqual(formatUpdatedLabel(now.addingTimeInterval(-120), now: now), "Updated 2m ago")
    expectEqual(formatUpdatedLabel(now.addingTimeInterval(-7200), now: now), "Updated 2h ago")
}

// MARK: - Severity thresholds

expectEqual(severity(forRemainingPercent: 100), .normal)
expectEqual(severity(forRemainingPercent: 26), .normal)
expectEqual(severity(forRemainingPercent: 25), .warning)
expectEqual(severity(forRemainingPercent: 10), .critical)
expectEqual(severity(forRemainingPercent: 0), .critical)
expect(UsageSeverity.critical > UsageSeverity.warning && UsageSeverity.warning > UsageSeverity.normal, "severity ordering")

// MARK: - Preferences (in-memory suite)

do {
    let suiteName = "claude-gauge-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    expectEqual(AppPreferences.displayMode(defaults: defaults), .remaining, "default numbers = remaining")
    AppPreferences.setDisplayMode(.used, defaults: defaults)
    expectEqual(AppPreferences.displayMode(defaults: defaults), .used)

    expectEqual(AppPreferences.menuBarLayout(defaults: defaults), .compact, "default layout")
    AppPreferences.setMenuBarLayout(.full, defaults: defaults)
    expectEqual(AppPreferences.menuBarLayout(defaults: defaults), .full)

    expectEqual(AppPreferences.pollInterval(defaults: defaults), 60, "default poll")
    AppPreferences.setPollInterval(300, defaults: defaults)
    expectEqual(AppPreferences.pollInterval(defaults: defaults), 300)
    AppPreferences.setPollInterval(7, defaults: defaults)
    expectEqual(AppPreferences.pollInterval(defaults: defaults), 60, "unsupported interval falls back")
    expectEqual(AppPreferences.formatPollInterval(30), "30 s")
    expectEqual(AppPreferences.formatPollInterval(60), "1 min")
    expectEqual(AppPreferences.formatPollInterval(300), "5 min")
}

// MARK: - Credentials JSON (synthetic values only)

private let credentialsFixture = """
{"claudeAiOauth":{"accessToken":"sk-ant-oat01-TESTACCESS","refreshToken":"sk-ant-ort01-TESTREFRESH","expiresAt":1790000000000,"refreshTokenExpiresAt":1792000000000,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"tier_x"},"otherTopLevel":{"keep":true}}
"""

do {
    let data = Data(credentialsFixture.utf8)
    guard let creds = parseClaudeCredentials(data) else {
        failures += 1
        fputs("FAIL: credentials fixture did not parse\n", stderr)
        exit(1)
    }
    expectEqual(creds.accessToken, "sk-ant-oat01-TESTACCESS")
    expectEqual(creds.refreshToken, "sk-ant-ort01-TESTREFRESH")
    expectEqual(creds.subscriptionType, "max")
    expectEqual(creds.scopes.count, 2)
    expectEqual(creds.expiresAt.map { Int($0.timeIntervalSince1970) }, 1_790_000_000)

    let before = Date(timeIntervalSince1970: 1_789_999_900) // 100 s before expiry
    expect(credentialsNeedRefresh(creds, now: before), "within 5 min leeway → refresh")
    expect(!credentialsNeedRefresh(creds, now: Date(timeIntervalSince1970: 1_789_999_000)), "1000 s before expiry → keep")
    let wellBefore = Date(timeIntervalSince1970: 1_789_990_000)
    expect(!credentialsNeedRefresh(creds, now: wellBefore), "10000 s before expiry → keep")
    expect(credentialsNeedRefresh(creds, now: Date(timeIntervalSince1970: 1_790_000_001)), "expired → refresh")

    let now = Date(timeIntervalSince1970: 1_790_100_000)
    guard let merged = mergeRefreshedCredentials(
        into: data,
        accessToken: "sk-ant-oat01-NEWACCESS",
        refreshToken: "sk-ant-ort01-NEWREFRESH",
        expiresIn: 28_800,
        scopes: nil,
        now: now
    ), let reparsed = parseClaudeCredentials(merged),
       let root = (try? JSONSerialization.jsonObject(with: merged)) as? [String: Any],
       let oauth = root["claudeAiOauth"] as? [String: Any]
    else {
        failures += 1
        fputs("FAIL: merge failed\n", stderr)
        exit(1)
    }
    expectEqual(reparsed.accessToken, "sk-ant-oat01-NEWACCESS")
    expectEqual(reparsed.refreshToken, "sk-ant-ort01-NEWREFRESH")
    expectEqual(reparsed.expiresAt.map { Int($0.timeIntervalSince1970) }, 1_790_128_800, "now + expires_in")
    expectEqual(reparsed.scopes, ["user:inference", "user:profile"], "scopes preserved when refresh omits them")
    expectEqual(reparsed.subscriptionType, "max", "unmodelled oauth keys preserved")
    expectEqual(oauth["rateLimitTier"] as? String, "tier_x", "rateLimitTier preserved")
    expectEqual((root["otherTopLevel"] as? [String: Any])?["keep"] as? Bool, true, "top-level siblings preserved")
    expectEqual(
        (oauth["refreshTokenExpiresAt"] as? NSNumber)?.int64Value, 1_792_000_000_000,
        "refresh expiry untouched"
    )

    // Refresh without a rotated refresh token keeps the old one.
    if let merged2 = mergeRefreshedCredentials(
        into: data, accessToken: "A2", refreshToken: nil, expiresIn: 10, scopes: ["x"], now: now
    ), let re2 = parseClaudeCredentials(merged2) {
        expectEqual(re2.refreshToken, "sk-ant-ort01-TESTREFRESH", "old refresh kept")
        expectEqual(re2.scopes, ["x"], "scopes replaced when provided")
    } else {
        failures += 1
        fputs("FAIL: merge2 failed\n", stderr)
    }

    expect(parseClaudeCredentials(Data("{}".utf8)) == nil, "empty JSON rejected")
    expect(parseClaudeCredentials(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil, "blank token rejected")
}

// MARK: - Refresh lock (temp home)

do {
    let home = NSTemporaryDirectory() + "claude-gauge-lock-\(UUID().uuidString)"
    let claudeDir = home + "/.claude"
    try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }

    let semaphore = DispatchSemaphore(value: 0)
    var ran = false
    var lockedDuring = false
    var cleanedAfter = false
    Task {
        let result = await RefreshLock.withLock(home: home, staleAfter: 10, attempts: 4, retryDelay: 0.01) {
            ran = true
            var isDir: ObjCBool = false
            lockedDuring = FileManager.default.fileExists(atPath: RefreshLock.lockPath(home: home), isDirectory: &isDir) && isDir.boolValue
            return 42
        }
        cleanedAfter = !FileManager.default.fileExists(atPath: RefreshLock.lockPath(home: home))
        expectEqual(result, 42, "lock returns body value")
        semaphore.signal()
    }
    semaphore.wait()
    expect(ran, "body ran")
    expect(lockedDuring, "lock dir existed during body")
    expect(cleanedAfter, "lock dir removed after body")

    // Fresh foreign lock → give up (nil); stale foreign lock → reclaimed.
    let lockPath = RefreshLock.lockPath(home: home)
    try? FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: false)
    let semaphore2 = DispatchSemaphore(value: 0)
    Task {
        let busy = await RefreshLock.withLock(home: home, staleAfter: 60, attempts: 3, retryDelay: 0.01) { 1 }
        expect(busy == nil, "fresh lock held elsewhere → nil")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: lockPath
        )
        let reclaimed = await RefreshLock.withLock(home: home, staleAfter: 60, attempts: 3, retryDelay: 0.01) { 2 }
        expectEqual(reclaimed, 2, "stale lock reclaimed")
        semaphore2.signal()
    }
    semaphore2.wait()
}

// MARK: - Launch at Login copy

expectEqual(formatLaunchAtLoginStatus(.enabled), "Registered — opens at login")
expect(formatLaunchAtLoginStatus(.requiresApproval).localizedCaseInsensitiveContains("approval"), "approval status")
expect(formatLaunchAtLoginLimitation(isInApplications: false).contains("/Applications"), "limitation mentions Applications")
expect(!formatLaunchAtLoginLimitation(isInApplications: true).contains("local build"), "in-apps hint is short")

if failures > 0 {
    fputs("\(failures) test failure(s)\n", stderr)
    exit(1)
}

print("All ClaudeGaugeCoreTests passed.")
