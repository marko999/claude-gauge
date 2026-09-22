# ClaudeGauge

**Claude Code plan limits, at a glance.**

macOS menu-bar app that shows how much of your Claude subscription is left — the rolling **5-hour** window, the **weekly** cap and per-model weekly caps — with reset countdowns, one click (or **⌥⌘K**) away.

```
5h 96% · W·Fable 83%        ← menu bar (remaining %, tightest weekly picked automatically)
```

> Not affiliated with Anthropic. Uses the same undocumented OAuth usage endpoint that `/usage` in Claude Code calls; it can change without notice.

## ✨ Features

- 📊 Menu bar: `5h 96% · W 83%` — remaining (default) or used %, compact or every limit
- 🟢🟠🔴 Title turns orange below 25 % left and red below 10 %
- 🪟 Popover: one bar per limit (5-hour, weekly · all models, weekly · per model), reset countdown + wall-clock time, extra-usage credits when enabled
- ⌨️ **⌥⌘K** opens the panel even if the icon is crowded out of the menu bar
- 🔁 Polls every 60 s (30 s – 5 min configurable), refreshes on wake and focus
- 🔒 Reuses your existing `claude auth login`; refreshes the OAuth token when it expires and writes it back so the CLI stays signed in
- 🖥️ Hidden CLI: `ClaudeGauge --status` prints the same text for scripts and statuslines
- ⚙️ Optional Launch at Login

## 🚀 Install

1. Grab the latest **arm64** zip from [Releases](https://github.com/marko999/claude-gauge/releases)
2. Unzip → right-click `ClaudeGauge.app` → **Open** (ad-hoc signed, not notarized)
3. Optional: move it to `/Applications` (needed for reliable Launch at Login)
4. Make sure Claude Code is signed in on this Mac:

```bash
claude auth login
```

Quit from the panel, or `pkill -x ClaudeGauge`.

## 🔐 Privacy (short)

- Reads the `Claude Code-credentials` item from your login Keychain (what `claude auth login` writes)
- Talks only to `api.anthropic.com` (usage) and `platform.claude.com` / `console.anthropic.com` (token refresh)
- Writes **only** the refreshed OAuth pair back to that same Keychain item — refresh tokens are single-use, so not doing this would log Claude Code out
- No telemetry, no other files, nothing sent to this repo's authors

Details: [SECURITY.md](SECURITY.md)

## 🧰 Statusline / scripts

```bash
/Applications/ClaudeGauge.app/Contents/MacOS/ClaudeGauge --status            # 5h 96% · W·Fable 83%
/Applications/ClaudeGauge.app/Contents/MacOS/ClaudeGauge --status --used --full --verbose
```

## 🛠️ Build

```bash
make test && make app
open dist/ClaudeGauge.app
```

`make run` rebuilds, restarts a running instance and opens the fresh bundle. See [CONTRIBUTING.md](CONTRIBUTING.md).

## ⚠️ Notes

- Needs Claude Code signed in on this Mac (`claude auth login`). The Claude **desktop app** keeps its own login and does not refresh the CLI's Keychain item.
- Apple Silicon (arm64) for the published zip
- Numbers are account-wide (CLI, desktop, web, mobile) — the same figures `/usage` shows

## License

MIT — see [LICENSE](LICENSE)
