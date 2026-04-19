# claude-statusline

> A rich, three-line status bar for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — works on **macOS, Linux, WSL2, and Windows**.

[![PayPal](https://img.shields.io/badge/PayPal-Donate-blue?logo=paypal)](https://paypal.me/VitaliiCherepanov)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL2%20%7C%20Windows-lightgrey)](#platform-support)

Displays real-time session metrics directly in your terminal — model, context usage, tokens, cost, duration, git branch, cache stats, subscription usage limits, and more.

```
Claude Opus 4.6 | [████████░░░░░░░░░░░░] 42% of 200.0K #1 | ↓156.8K ↑23.4K | cache r:89.0K w:45.0K
$1.47 | ⏱ 5m42s (api 3m18s) | +245/-31 | ⎇ main | 📂 my-project | [N]
5h [██████░░░░] 68% ↻2h41m | 7d [████░░░░░░] 48% ↻1d20h
```

---

## Why this exists

Claude Code's built-in status line shows the model name and a terse percentage. That's fine until you:

- **Burn through your 5-hour / 7-day subscription quota** without noticing and get cut off mid-task.
- **Hit context auto-compaction** and lose state because you didn't see 85% approaching.
- **Rack up API cost** on long sessions with no live $ counter.
- **Lose track of cache hits vs writes** when debugging performance.
- **Switch between projects** and forget which branch you're on.

`claude-statusline` solves all of it in a single shell script — zero runtime dependencies beyond `jq` and `curl`, ~20 ms per update, no daemon, no background process.

## What it shows

### Line 1 — model, context, tokens, cache

```
Model | [████░░░░░░░░] PCT% of SIZE #W | ↓input ↑output | cache r:READ w:WRITE
```

- **Model name** — which Claude model is active (color: cyan bold)
- **Context usage bar** — 20-char visual progress bar with color thresholds (green < 70% → yellow < 90% → red)
- **Compaction counter `#N`** — increments every time the context window gets compacted during a session
- **Token counts** — input (`↓`) and output (`↑`) with `K`/`M` formatting
- **Cache stats** — cache read / write token counts

### Line 2 — cost, time, diff, git, context

```
$COST | ⏱ DURATION (api API_DUR) | +ADDED/-REMOVED | ⎇ BRANCH | 📂 DIR | [N]
```

- **Cost** in USD (yellow)
- **Duration** total and API-only separately
- **Lines added/removed** during the session
- **Git branch** (when in a repo)
- **Working directory name**
- **Vim mode** `[N]` / `[I]` indicator (when vim mode is active)
- **Sub-agent name** (when an agent is running)
- **`⚠ >200K`** warning when tokens exceed 200K

### Line 3 — subscription quota

```
5h [██████░░░░] 68% ↻2h41m | 7d [████░░░░░░] 48% ↻1d20h
```

Real subscription limits pulled from `https://api.anthropic.com/api/oauth/usage` (cached 2 min). Shows **remaining** quota with a fuel-gauge colour (green > 50% → yellow > 20% → red) and countdown to reset. Only appears when you're logged in via `claude.ai` OAuth (not API key).

---

## Platform support

| Feature | macOS | Linux | WSL2 | Windows (Git Bash) |
|---|:-:|:-:|:-:|:-:|
| 3-line status bar | ✅ | ✅ | ✅ | ✅ |
| Usage limits (OAuth) | ✅ Keychain | ✅ libsecret → file | ✅ file | ✅ Cred Manager → file |
| Desktop notifications | ✅ `osascript` | ✅ `notify-send`* | ✅ `notify-send`* | ✅ `BurntToast`* |
| Installer | `install.sh` | `install.sh` | `install.sh` | `install.ps1` |

<sub>`*` — optional. If the notifier isn't installed the feature silently no-ops (status line still works).</sub>

**WSL2** is treated as Linux (detected via `/proc/version`). If you want native Windows toast notifications from inside WSL2 you'll need WSLg + a Linux notifier, or invoke `BurntToast` via `powershell.exe`.

---

## Requirements

- **jq** — JSON processor
- **curl** — for usage limits API (skips gracefully if missing)
- **bash** — 3.2+ (macOS default) or any modern 4/5
- **Claude Code CLI** — v1.0+ with status line support
- Optional: `notify-send` (Linux), `libsecret-tools` (Linux), `BurntToast` (Windows)

Install `jq` on your platform:

| OS | Command |
|---|---|
| macOS | `brew install jq` |
| Debian/Ubuntu | `sudo apt-get install jq` |
| Fedora/RHEL | `sudo dnf install jq` |
| Arch | `sudo pacman -S jq` |
| Alpine | `sudo apk add jq` |
| Windows | `winget install jqlang.jq` or `choco install jq` |

---

## Installation

### macOS / Linux / WSL2

```bash
git clone https://github.com/vbcherepanov/claude-statusbar.git
cd claude-statusbar
bash install.sh
```

### Windows (Git Bash + PowerShell)

```powershell
git clone https://github.com/vbcherepanov/claude-statusbar.git
cd claude-statusbar
powershell -ExecutionPolicy Bypass -File install.ps1
```

(You can also run `bash install.sh` inside Git Bash on Windows — it'll work the same way.)

The installer will:
1. Detect your OS and check dependencies with platform-specific install hints
2. Copy `statusline.sh` to `~/.claude/statusline.sh`
3. Add the `statusLine` config to `~/.claude/settings.json`
4. Prompt before overwriting existing files

### Manual install

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/ABSOLUTE/PATH/TO/.claude/statusline.sh",
    "padding": 2
  }
}
```

On Windows the `command` is `bash 'C:/Users/YOU/.claude/statusline.sh'`.

Restart Claude Code.

---

## How it works

Claude Code pipes session JSON to stdin every ~300 ms. The script:

1. **Parses all 16 fields in a single `jq` call** with `@sh` for safe eval
2. **Formats values in pure bash** (no `bc`, no `awk`, no extra subshells)
3. **Fetches usage limits** with a 2-minute cache (background on macOS/Windows, sync on Linux/WSL2 — because Claude Code kills backgrounded child processes on exit)
4. **Writes threshold flags** at 70% / 85% / 95% context for hook integration
5. **Outputs three ANSI-coloured lines**

Execution time: **~20 ms** on macOS (cache warm), **~100 ms** on Linux cold start.

The code is a single self-contained shell script (~320 lines). No daemon. No database. No network except the cached usage-limits endpoint.

---

## Configuration

All toggles are environment variables — set them in your shell profile or a wrapper script.

| Variable | Default | Purpose |
|---|---|---|
| `STATUSLINE_USAGE_LIMITS` | `1` | Set `0` to disable 5h/7d line (no network calls) |
| `STATUSLINE_WINDOW_COUNTER` | `1` | Set `0` to disable `#N` compaction counter |
| `STATUSLINE_FLAGS` | `1` | Set `0` to disable threshold flag files |
| `STATUSLINE_FLAG_DIR` | `~/.claude/.context-flags` | Custom directory for flag files |

### CLI flags

```
statusline.sh --version   # prints: claude-statusline 1.1.0
statusline.sh --help      # flags, env vars, and link to repo
```

### Threshold flags

When context usage crosses 70 / 85 / 95 %, the script writes a JSON file to `$STATUSLINE_FLAG_DIR`. Claude Code hooks can watch this directory to trigger auto-save, notifications, or whatever else.

```json
{"pct":87,"in":"156.8K","out":"23.4K","cost":"$1.47","dur":"5m42s","cwd":"/path","t":"2026-04-19T16:06:42Z"}
```

At 85% and 95% you also get a native desktop notification (macOS / Linux / WSL2 / Windows — see [Platform support](#platform-support)).

---

## Usage limits — credential resolution

Fetches subscription quota using your Claude OAuth token. The script tries, in order:

1. **macOS** — Keychain via `security find-generic-password`
2. **Windows** — Credential Manager via `powershell.exe` + `CredentialManager` module
3. **Linux/WSL2** — libsecret via `secret-tool`
4. **Everywhere** — fallback to `~/.claude/.credentials.json` (`0600` perms)

The file fallback is what makes Linux work out-of-the-box (Claude Code doesn't write to the Linux keyring). It's also why you can have a broken keyring on macOS/Windows and the script still works.

Requires `claude.ai` OAuth login. API-key users will simply not see line 3.

---

## Testing

```bash
cat examples/sample-input.json | bash statusline.sh
```

You can pipe this to the script on any platform to see a rendered status line without launching Claude Code.

---

## Uninstall

```bash
bash uninstall.sh
```

Or manually:

```bash
rm ~/.claude/statusline.sh
rm -rf ~/.claude/.context-flags ~/.claude/.usage-cache.json
# Remove the "statusLine" key from ~/.claude/settings.json
```

---

## Support the project

If this saves you time (or subscription cost), consider buying me a coffee:

[![PayPal](https://img.shields.io/badge/PayPal-Donate-blue?logo=paypal&style=for-the-badge)](https://paypal.me/VitaliiCherepanov)

There's also a **Sponsor** button at the top of the GitHub repo (`.github/FUNDING.yml` → PayPal).

---

## Contributing

Bug reports and PRs welcome, especially platform-specific fixes. The entire thing is one shell script — you can read it in 10 minutes.

Before a PR:

```bash
bash -n statusline.sh install.sh uninstall.sh        # syntax
shellcheck statusline.sh install.sh uninstall.sh     # lint (optional)
cat examples/sample-input.json | bash statusline.sh  # smoke test
```

## License

[MIT](LICENSE)
