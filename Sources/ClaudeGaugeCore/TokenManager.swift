import Foundation

public enum AccessTokenResult: Sendable {
    /// Usable token. `warning` is set when the refreshed pair could not be persisted.
    case ok(token: String, warning: String?)
    case needsLogin(String)
    case failed(String)
}

/// Owns the read → (refresh → write-back) dance for the Claude Code keychain login.
/// Refresh tokens are single-use, so a successful refresh must be written back or
/// the CLI will be logged out on its next start.
public actor ClaudeTokenManager {
    private let home: String
    private let service: String

    public init(home: String = NSHomeDirectory(), service: String = claudeCredentialsService) {
        self.home = home
        self.service = service
    }

    public func accessToken(forceRefresh: Bool = false) async -> AccessTokenResult {
        let credentials: ClaudeCredentials
        switch readClaudeCredentialsFromKeychain(service: service) {
        case .ok(let value):
            credentials = value
        case .missing:
            return .needsLogin("No Claude Code login found in Keychain. " + loginHint)
        case .failed(let message):
            return .failed(message)
        }

        if !forceRefresh && !credentialsNeedRefresh(credentials) {
            return .ok(token: credentials.accessToken, warning: nil)
        }
        return await refresh(previous: credentials, force: forceRefresh)
    }

    private func refresh(previous: ClaudeCredentials, force: Bool) async -> AccessTokenResult {
        let service = self.service
        let outcome = await RefreshLock.withLock(home: home) { () async -> AccessTokenResult in
            // Re-read under the lock: Claude Code may have rotated while we waited.
            guard case .ok(let latest) = readClaudeCredentialsFromKeychain(service: service) else {
                return .needsLogin("Claude Code login disappeared from Keychain. " + loginHint)
            }
            let rotatedElsewhere = latest.accessToken != previous.accessToken
            if rotatedElsewhere && !credentialsNeedRefresh(latest) {
                return .ok(token: latest.accessToken, warning: nil)
            }
            if !force && !credentialsNeedRefresh(latest) {
                return .ok(token: latest.accessToken, warning: nil)
            }
            guard let refreshToken = latest.refreshToken, !refreshToken.isEmpty else {
                return .needsLogin("Keychain login has no refresh token. " + loginHint)
            }
            if let refreshExpiry = latest.refreshTokenExpiresAt, refreshExpiry < Date() {
                return .needsLogin("Claude Code refresh token expired. " + loginHint)
            }

            switch await refreshOAuthToken(refreshToken: refreshToken) {
            case .ok(let access, let newRefresh, let expiresIn, let scopes):
                guard let merged = mergeRefreshedCredentials(
                    into: latest.rawJSON,
                    accessToken: access,
                    refreshToken: newRefresh,
                    expiresIn: expiresIn,
                    scopes: scopes
                ) else {
                    return .ok(token: access, warning: "Refreshed, but could not rebuild Keychain JSON.")
                }
                let account = keychainAccountName(service: service)
                if writeClaudeCredentialsToKeychain(merged, service: service, account: account) {
                    return .ok(token: access, warning: nil)
                }
                return .ok(
                    token: access,
                    warning: "Refreshed, but Keychain write-back failed — Claude Code may need `claude auth login`."
                )
            case .rejected(let message):
                if case .ok(let again) = readClaudeCredentialsFromKeychain(service: service),
                   again.accessToken != latest.accessToken,
                   !credentialsNeedRefresh(again)
                {
                    return .ok(token: again.accessToken, warning: nil)
                }
                return .needsLogin("Anthropic rejected the stored refresh token (\(message)). " + loginHint)
            case .failed(let message, _):
                if let expiresAt = latest.expiresAt, expiresAt > Date() {
                    // Still inside the leeway window: keep using the old token.
                    return .ok(token: latest.accessToken, warning: "Token refresh failed: \(message)")
                }
                return .failed(message)
            }
        }
        return outcome ?? .failed("Another process is refreshing the Claude login; retrying on next poll.")
    }
}
