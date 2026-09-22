# Contributing

Thanks for helping with ClaudeGauge.

## Prerequisites

- macOS 13+
- Apple Silicon recommended (current release packaging is arm64-only)
- Swift 5.9+ via Xcode or Command Line Tools
- Claude Code signed in (`claude auth login`) for manual testing

## Build & test

```bash
make test          # ClaudeGaugeCoreTests assert runner
make app           # dist/ClaudeGauge.app (ad-hoc signed)
make run           # rebuild + restart + open
make smoke-check   # bundle / codesign / credential-path scan
```

Optional local release zip (not committed):

```bash
make release-zip   # dist/ClaudeGauge-v<version>-macOS-arm64.zip + .sha256
```

## Workflow

1. Fork and branch from `main`.
2. Keep changes focused; preserve the security model in [SECURITY.md](SECURITY.md) (tokens only in memory, write-back only to the existing Keychain item, no logging).
3. Run `make test` and `make app` before opening a PR.
4. Do not commit `.build/`, `dist/`, zip/checksum artifacts, env files, or credentials.

## Code layout

- `Sources/ClaudeGaugeCore` — credentials + Keychain, token refresh, usage API, parsing, formatting, preferences (testable, no AppKit)
- `Sources/ClaudeGauge` — AppKit menu-bar UI, hotkey, launch-at-login, `--status` CLI
- `Tests/ClaudeGaugeCoreTests` — CLT-friendly assert runner (no XCTest)

## License

By contributing, you agree your contributions are licensed under the MIT License in `LICENSE`.
