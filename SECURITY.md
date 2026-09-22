# Security Policy

## Supported versions

Security fixes are considered for the latest published release on GitHub.

## Reporting a vulnerability

Please report security issues privately:

1. Prefer [GitHub Security Advisories](https://github.com/marko999/claude-gauge/security/advisories/new) for this repository, **or**
2. Open a GitHub issue **without** secrets, tokens, Keychain dumps or personal usage figures — describe impact and reproduction at a high level, then request a private channel.

Do **not** attach `sk-ant-oat…` / `sk-ant-ort…` tokens, Keychain exports, `~/.claude.json`, or screenshots that show account details.

## Token-handling / security model

ClaudeGauge is an unofficial local helper. It:

- Reads the `Claude Code-credentials` generic-password item from the login Keychain via `/usr/bin/security` — the same item `claude auth login` writes. Nothing is read from the Claude desktop app.
- Holds tokens **only in memory** and sends the access token only as an HTTPS `Authorization: Bearer` header to `api.anthropic.com`.
- When the access token is within 5 minutes of expiry (or the API answers 401), it calls the OAuth token endpoint (`platform.claude.com`, fallback `console.anthropic.com`) with the stored refresh token and Claude Code's public client id.
- **Writes the refreshed pair back** to the same Keychain item (`security add-generic-password -U`), preserving every other field, and verifies by reading it back. Refresh tokens are single-use; skipping the write-back would leave Claude Code with a dead refresh token.
- Coordinates with Claude Code through the same `~/.claude/.oauth_refresh.lock` directory lock so two processes never rotate the token at once.
- Never writes tokens to logs, preferences, the app bundle or release artifacts. Error strings shown in the UI are sanitized (no bodies, no bearer values).

Known trade-off: the write-back passes the JSON payload as an argument to `/usr/bin/security`, which is briefly visible to other processes of the same user via `ps`. Any such process can already read the item with `security find-generic-password`, so this does not widen the threat model.

Threat model assumptions:

- The Mac user already trusts Claude Code and its Keychain login.
- Anyone who can read the login Keychain can obtain the same session material.
- Network traffic goes only to Anthropic endpoints; this project operates no backend.

## What we will not accept in public issues

- Pasted access or refresh tokens
- Keychain exports or `~/.claude.json` copies
- Requests to bypass Gatekeeper, disable SIP, or otherwise weaken macOS security for distribution
