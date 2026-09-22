import Foundation

public let claudeGaugeVersion = "0.2.1"

/// Usage endpoint behind `/usage` in Claude Code.
public let claudeAPIOrigin = "https://api.anthropic.com"
private let usagePath = "/api/oauth/usage"
private let oauthBetaHeader = "oauth-2025-04-20"

/// OAuth token endpoints (newest first) and Claude Code's public client id.
public let claudeOAuthTokenEndpoints = [
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
]
public let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

public let claudeUsageSettingsURL = URL(string: "https://claude.ai/settings/usage")!

/// Identify honestly. The OAuth token endpoint answers 429 to any User-Agent that
/// claims to be `claude-code/...` without the real client's fingerprint, while the
/// usage endpoint accepts this UA fine (verified 2026-09-22).
private let userAgent = "ClaudeGauge/\(claudeGaugeVersion) (+https://github.com/marko999/claude-gauge)"

private let allowedHosts: Set<String> = [
    "api.anthropic.com",
    "platform.claude.com",
    "console.anthropic.com",
]

public enum UsageFetchResult: Sendable {
    case ok(UsageSnapshot)
    case unauthorized(String)
    case failed(String, Int?)
}

public enum TokenRefreshResult: Sendable {
    case ok(accessToken: String, refreshToken: String?, expiresIn: TimeInterval, scopes: [String]?)
    /// The server rejected the refresh token itself (invalid_grant): user must log in again.
    case rejected(String)
    case failed(String, Int?)
}

private enum APIError: Error {
    case blocked(String)
    case invalidJSON(status: Int)
    case timeout
    case transport(String)
}

private func assertAllowedURL(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
        throw APIError.blocked("Only HTTPS Anthropic URLs are allowed.")
    }
    guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
        throw APIError.blocked("Request blocked: host is not an Anthropic origin.")
    }
}

private func sanitize(_ message: String) -> String {
    message
        .replacingOccurrences(
            of: #"Bearer\s+\S+"#, with: "Bearer [redacted]", options: .regularExpression
        )
        .replacingOccurrences(
            of: #"sk-ant-[A-Za-z0-9_\-]+"#, with: "sk-ant-[redacted]", options: .regularExpression
        )
}

private actor URLSessionHolder {
    static let shared = URLSessionHolder()
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
}

private func performJSONRequest(_ request: URLRequest) async throws -> (status: Int, json: Any?) {
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSessionHolder.shared.session.data(for: request)
    } catch let urlError as URLError where urlError.code == .timedOut {
        throw APIError.timeout
    } catch {
        throw APIError.transport(sanitize(error.localizedDescription))
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if data.isEmpty {
        return (status, nil)
    }
    do {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return (status, json)
    } catch {
        // Never attach the raw body — it may contain account details.
        throw APIError.invalidJSON(status: status)
    }
}

private func mapAPIError(_ error: APIError) -> (String, Int?) {
    switch error {
    case .blocked(let message):
        return (message, nil)
    case .invalidJSON(let status):
        return ("Invalid JSON from Anthropic (HTTP \(status)).", status)
    case .timeout:
        return ("Anthropic request timed out.", nil)
    case .transport(let message):
        return (message, nil)
    }
}

private func errorCode(in json: Any?) -> String? {
    guard let root = asRecord(json) else { return nil }
    if let error = asRecord(root["error"]) {
        return (error["type"] as? String) ?? (error["code"] as? String)
    }
    return root["error"] as? String
}

private func errorMessage(in json: Any?) -> String? {
    guard let root = asRecord(json) else { return nil }
    if let error = asRecord(root["error"]) {
        return error["message"] as? String
    }
    return root["error_description"] as? String
}

/// `GET /api/oauth/usage` with the OAuth bearer. Token is never logged.
public func fetchUsage(accessToken: String) async -> UsageFetchResult {
    do {
        guard let url = URL(string: claudeAPIOrigin + usagePath) else {
            throw APIError.blocked("Invalid usage URL.")
        }
        try assertAllowedURL(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let result = try await performJSONRequest(request)
        switch result.status {
        case 200..<300:
            if let snapshot = parseUsageResponse(result.json) {
                return .ok(snapshot)
            }
            return .failed("Usage payload shape not recognized (API may have changed).", result.status)
        case 401, 403:
            let detail = errorMessage(in: result.json).map { " \($0)" } ?? ""
            return .unauthorized("Claude session rejected (HTTP \(result.status)).\(sanitize(detail))")
        case 429:
            return .failed("Rate limited by Anthropic; will retry on the next poll.", 429)
        default:
            return .failed("Usage request failed (HTTP \(result.status)).", result.status)
        }
    } catch let error as APIError {
        let mapped = mapAPIError(error)
        return .failed(mapped.0, mapped.1)
    } catch {
        return .failed(sanitize(error.localizedDescription), nil)
    }
}

private func parseTokenResponse(_ json: Any?) -> TokenRefreshResult? {
    guard let root = asRecord(json),
          let access = root["access_token"] as? String,
          !access.isEmpty
    else {
        return nil
    }
    let expiresIn = asDouble(root["expires_in"]) ?? 8 * 3600
    var scopes: [String]?
    if let scope = root["scope"] as? String, !scope.isEmpty {
        scopes = scope.split(separator: " ").map(String.init)
    } else if let list = root["scope"] as? [String] {
        scopes = list
    }
    return .ok(
        accessToken: access,
        refreshToken: root["refresh_token"] as? String,
        expiresIn: expiresIn,
        scopes: scopes
    )
}

private func formEncode(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body = fields.map { key, value -> String in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }.joined(separator: "&")
    return Data(body.utf8)
}

/// Rotate the OAuth pair. Tries JSON then form encoding on each known endpoint.
public func refreshOAuthToken(refreshToken: String) async -> TokenRefreshResult {
    let fields: [(String, String)] = [
        ("grant_type", "refresh_token"),
        ("refresh_token", refreshToken),
        ("client_id", claudeOAuthClientID),
    ]
    var lastFailure: TokenRefreshResult = .failed("No OAuth token endpoint accepted the refresh.", nil)

    for endpoint in claudeOAuthTokenEndpoints {
        guard let url = URL(string: endpoint) else { continue }
        do {
            try assertAllowedURL(url)
        } catch let error as APIError {
            let mapped = mapAPIError(error)
            return .failed(mapped.0, mapped.1)
        } catch {
            return .failed(sanitize(error.localizedDescription), nil)
        }

        for useJSON in [true, false] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if useJSON {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: String] = [:]
                for (key, value) in fields {
                    body[key] = value
                }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            } else {
                request.setValue(
                    "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
                )
                request.httpBody = formEncode(fields)
            }

            do {
                let result = try await performJSONRequest(request)
                if (200..<300).contains(result.status), let parsed = parseTokenResponse(result.json) {
                    return parsed
                }
                let code = errorCode(in: result.json) ?? ""
                if code == "invalid_grant" {
                    return .rejected(sanitize(errorMessage(in: result.json) ?? "invalid_grant"))
                }
                if result.status == 404 || result.status == 405 {
                    lastFailure = .failed("Token endpoint not found (HTTP \(result.status)).", result.status)
                    break // next endpoint
                }
                let detail = errorMessage(in: result.json) ?? code
                lastFailure = .failed(
                    "Token refresh failed (HTTP \(result.status))\(detail.isEmpty ? "" : ": " + sanitize(detail))",
                    result.status
                )
                // 400 / 415 with JSON → retry same endpoint form-encoded; otherwise move on.
                if !(result.status == 400 || result.status == 415) {
                    break
                }
            } catch let error as APIError {
                let mapped = mapAPIError(error)
                lastFailure = .failed(mapped.0, mapped.1)
                break
            } catch {
                lastFailure = .failed(sanitize(error.localizedDescription), nil)
                break
            }
        }
    }
    return lastFailure
}
