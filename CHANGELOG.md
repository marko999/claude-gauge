# Changelog

## v0.2.1

- Menu-bar progress bars now draw the full 100 % track as an outlined capsule, so the filled part is readable against the translucent menu bar; bars are slightly larger (34×9)

## v0.2.0

- **Menu bar shows** setting: 5-hour session on/off; weekly = none / tightest only / every weekly limit (replaces compact/full; old preference migrates)
- **Menu bar style** setting: text, progress bars, or progress bars + % — bars are tinted green / orange / red by remaining headroom and follow light/dark appearance
- `--status --session-only` CLI flag
- Hidden `--snapshot <dir>` renders the README images from live data (no screen-recording permission needed)
- README with light/dark screenshots

## v0.1.0

First release of **ClaudeGauge** (sibling of [CursorGauge](https://github.com/marko999/cursor-gauge)).

- Native macOS menu-bar gauge for Claude Code plan limits: 5-hour session, weekly · all models, weekly · per model
- Menu bar shows remaining % (or used %), compact (5h + tightest weekly) or every limit; orange < 25 %, red < 10 %
- Popover with one capacity bar per limit, reset countdown + wall-clock time, extra-usage credits when enabled
- Hotkey **⌥⌘K** toggles the panel
- Reuses the Claude Code Keychain login; refreshes the OAuth token on expiry and writes it back (cooperative lock with the CLI)
- `ClaudeGauge --status` CLI output for statuslines
- Launch at Login via `SMAppService` (optional; off by default)
- Ad-hoc signed **arm64** app bundle (not notarized)
