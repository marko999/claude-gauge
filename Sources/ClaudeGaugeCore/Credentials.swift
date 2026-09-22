import Foundation

/// Keychain item written by Claude Code (`claude auth login`).
public let claudeCredentialsService = "Claude Code-credentials"
public let loginHint = "Run `claude auth login` in Terminal, then Refresh."

private let securityPath = "/usr/bin/security"
private let oauthKey = "claudeAiOauth"

public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var subscriptionType: String?
    public var scopes: [String]
    /// Original JSON document, preserved verbatim so write-back never drops
    /// fields this app does not model.
    public var rawJSON: Data

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil,
        subscriptionType: String? = nil,
        scopes: [String] = [],
        rawJSON: Data
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.subscriptionType = subscriptionType
        self.scopes = scopes
        self.rawJSON = rawJSON
    }
}

private func dateFromMillis(_ value: Any?) -> Date? {
    guard let millis = asDouble(value), millis > 0 else { return nil }
    return Date(timeIntervalSince1970: millis / 1000)
}

public func parseClaudeCredentials(_ data: Data) -> ClaudeCredentials? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let oauth = root[oauthKey] as? [String: Any],
          let access = oauth["accessToken"] as? String,
          !access.isEmpty
    else {
        return nil
    }
    return ClaudeCredentials(
        accessToken: access,
        refreshToken: oauth["refreshToken"] as? String,
        expiresAt: dateFromMillis(oauth["expiresAt"]),
        refreshTokenExpiresAt: dateFromMillis(oauth["refreshTokenExpiresAt"]),
        subscriptionType: oauth["subscriptionType"] as? String,
        scopes: (oauth["scopes"] as? [String]) ?? [],
        rawJSON: data
    )
}

/// True when the access token is expired or expires within `leeway`.
public func credentialsNeedRefresh(
    _ credentials: ClaudeCredentials,
    now: Date = Date(),
    leeway: TimeInterval = 5 * 60
) -> Bool {
    guard let expiresAt = credentials.expiresAt else { return false }
    return expiresAt.timeIntervalSince(now) <= leeway
}

/// Produce the JSON Claude Code expects, keeping every unrelated key intact.
public func mergeRefreshedCredentials(
    into original: Data,
    accessToken: String,
    refreshToken: String?,
    expiresIn: TimeInterval,
    scopes: [String]?,
    now: Date = Date()
) -> Data? {
    guard var root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
        return nil
    }
    var oauth = (root[oauthKey] as? [String: Any]) ?? [:]
    oauth["accessToken"] = accessToken
    if let refreshToken, !refreshToken.isEmpty {
        oauth["refreshToken"] = refreshToken
    }
    oauth["expiresAt"] = NSNumber(value: Int64((now.timeIntervalSince1970 + expiresIn) * 1000))
    if let scopes, !scopes.isEmpty {
        oauth["scopes"] = scopes
    }
    root[oauthKey] = oauth
    return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

// MARK: - /usr/bin/security wrapper

private struct ProcessOutput {
    var status: Int32
    var stdout: Data
}

private func runSecurity(_ arguments: [String], timeoutSeconds: TimeInterval = 15) -> ProcessOutput? {
    guard FileManager.default.isExecutableFile(atPath: securityPath) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: securityPath)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin"]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return nil
    }

    // Drain both pipes on background threads so a large payload cannot block the child.
    var outData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        // Discard stderr without logging — may echo item metadata.
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning {
        if Date() > deadline {
            process.terminate()
            return nil
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    group.wait()
    return ProcessOutput(status: process.terminationStatus, stdout: outData)
}

public enum KeychainReadResult: Sendable {
    case ok(ClaudeCredentials)
    case missing
    case failed(String)
}

/// Read the Claude Code login. Token bytes stay in memory only.
public func readClaudeCredentialsFromKeychain(
    service: String = claudeCredentialsService
) -> KeychainReadResult {
    guard let result = runSecurity(["find-generic-password", "-s", service, "-w"]) else {
        return .failed("Could not run /usr/bin/security.")
    }
    guard result.status == 0 else {
        return .missing
    }
    var data = result.stdout
    while let last = data.last, last == 0x0A || last == 0x0D {
        data.removeLast()
    }
    guard let credentials = parseClaudeCredentials(data) else {
        return .failed("Keychain item \"\(service)\" has an unexpected format.")
    }
    return .ok(credentials)
}

/// Account name of the existing item (Claude Code uses the macOS username).
public func keychainAccountName(service: String = claudeCredentialsService) -> String {
    if let result = runSecurity(["find-generic-password", "-s", service]),
       result.status == 0,
       let text = String(data: result.stdout, encoding: .utf8)
    {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"acct\"") else { continue }
            if let eq = trimmed.range(of: "=\"") {
                var value = String(trimmed[eq.upperBound...])
                if value.hasSuffix("\"") {
                    value.removeLast()
                }
                if !value.isEmpty {
                    return value
                }
            }
        }
    }
    return NSUserName()
}

/// Replace the item in place (`-U`) and verify by reading it back.
/// The refreshed token must be persisted, or Claude Code's stored refresh token
/// (single-use) becomes stale and the CLI logs itself out.
public func writeClaudeCredentialsToKeychain(
    _ json: Data,
    service: String = claudeCredentialsService,
    account: String
) -> Bool {
    guard let payload = String(data: json, encoding: .utf8),
          let expected = parseClaudeCredentials(json)
    else {
        return false
    }
    guard let result = runSecurity([
        "add-generic-password", "-U", "-a", account, "-s", service, "-w", payload,
    ]), result.status == 0 else {
        return false
    }
    guard case .ok(let stored) = readClaudeCredentialsFromKeychain(service: service) else {
        return false
    }
    return stored.accessToken == expected.accessToken
        && stored.refreshToken == expected.refreshToken
}

// MARK: - Cooperative refresh lock (same directory lock Claude Code uses)

public enum RefreshLock {
    public static func lockPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".claude/.oauth_refresh.lock")
    }

    /// Runs `body` while holding `~/.claude/.oauth_refresh.lock` (mkdir-style lock,
    /// stale after `staleAfter`). Returns nil if the lock could not be obtained.
    public static func withLock<T>(
        home: String = NSHomeDirectory(),
        staleAfter: TimeInterval = 10,
        attempts: Int = 40,
        retryDelay: TimeInterval = 0.25,
        body: () async -> T
    ) async -> T? {
        let fm = FileManager.default
        let claudeDir = (home as NSString).appendingPathComponent(".claude")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: claudeDir, isDirectory: &isDir), isDir.boolValue else {
            // Claude Code has never run here; nothing to coordinate with.
            return await body()
        }

        let path = lockPath(home: home)
        for _ in 0..<max(1, attempts) {
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
                let value = await body()
                try? fm.removeItem(atPath: path)
                return value
            } catch {
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let modified = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) > staleAfter,
                   let contents = try? fm.contentsOfDirectory(atPath: path),
                   contents.isEmpty
                {
                    try? fm.removeItem(atPath: path)
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        return nil
    }
}
