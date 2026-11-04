# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] — 2026-11-04 — Plan-aware limits and Fable

### Fixed
- **Limits froze on old values.** A response with `five_hour: null` was rejected and never cached, and a failed request was retried on every render after the 2-minute TTL, which kept the endpoint returning HTTP 429. Failures now back off and honour `Retry-After`.
- **Plans without a 5-hour window** no longer show a `5h` gauge built from missing or expired data.
- **Reset times without fractional seconds** (`2026-11-05T04:00:00+00:00`, used by the Fable limit) broke parsing of the whole limits line.
- **PR badge** read `github.*`, which isn't in the documented stdin schema; it now reads `pr.*` and `workspace.repo`, keeping `github.*` as a fallback.
- **Git branch** was missing in subdirectories and linked worktrees.

### Added
- **Per-model gauges such as `Fable`**, from the `limits[]` rows of the undocumented usage endpoint.
- **Documented `rate_limits` stdin field** as the first source for `5h`/`7d`, plus `spend_limit` behind a Claude apps gateway.
- **README note** on enabling the built-in limit items in Codex CLI's own footer.
- **Subscription name** (`Pro`, `Ultra`, …) at the start of the limits line, from `/api/oauth/profile` with the OAuth credential as a fallback; `STATUSLINE_PLAN=0` hides it.
- **`~` marker** on values from a cache older than 15 minutes.
- **`tests/run.sh`** offline regression suite, run in CI.

### Changed
- Secondary text uses a light gray instead of the faint attribute, which was unreadable in many themes; `STATUSLINE_MUTED_COLOR` overrides it. The timer is bright blue.
- The usage request sends the OAuth token through stdin rather than `curl` arguments, and identifies itself as `claude-statusline/<version>`.
- Cache files are written atomically with owner-only permissions.

## [1.3.0] — 2026-05-20 — GitHub PR badge

> A `v1.2.0` git tag exists upstream (pointing at an older `Update
> FUNDING.yml` commit) but no GitHub Release was published for it. To keep
> the version line monotonic and avoid force-moving a published tag, this
> release ships as **v1.3.0** instead.

### Added
- **GitHub PR badge in line 2** — picks up `.github.repo` and `.github.pr.*`
  from Claude Code's stdin JSON (Claude Code **v2.1.145+** ships these fields
  whenever the current working directory resolves to a GitHub repo).
  - `🟢 PR#N` — open PR
  - `🟣 PR#N` — merged
  - `⚫ PR#N` — closed (not merged)
  - `🟡 PR#N` — draft
  - `· no PR` — repo detected but no PR is associated with the current branch
    (handy reminder on feature branches)
- `STATUSLINE_GITHUB=0` env var to hide the badge entirely.

### Changed
- `--version` now prints `claude-statusline 1.3.0`.
- README: line-2 anatomy expanded with the PR badge variants, configuration
  table gains `STATUSLINE_GITHUB`.

### Compatibility
- Older Claude Code (pre-v2.1.145) does not emit `.github.*` → the parser
  defaults to empty strings, no badge is rendered, behavior identical to 1.1.0.
- No new runtime dependencies. Still `jq` + `curl` only.

## [1.1.0] — 2026-04-19

### Added
- **First-class support for Linux, WSL2 and Windows** (Git Bash / MSYS2 / Cygwin), alongside existing macOS support.
- `_detect_os` helper detects `mac` / `linux` / `wsl` / `windows`.
- `_get_cred` — single credential reader with platform-native source (Keychain / libsecret / Credential Manager) and **universal fallback to `~/.claude/.credentials.json`**.
- `_fetch_usage` — single HTTP-fetch function used by both cold-start and warm refresh (no duplication).
- `_notify` — platform-aware notifier: `osascript` (macOS), `notify-send` (Linux/WSL2), `BurntToast` (Windows, optional). Silent no-op if notifier unavailable.
- Cold-start now fetches usage synchronously on **all** platforms (previously macOS/Windows showed empty line on first run).
- `--version` / `-v` and `--help` / `-h` flags.
- `install.ps1` — native PowerShell installer for Windows.
- `install.sh` — OS detection + package-manager aware dependency hints (`brew` / `apt` / `dnf` / `pacman` / `zypper` / `apk` / `choco` / `winget`).
- `CHANGELOG.md` (this file).
- `.gitignore`: `.idea/`, `.vscode/`.

### Changed
- Refactored `statusline.sh`: extracted platform logic into functions, eliminating the cold-start ↔ refresh duplication introduced by PR #1.
- `_stat_mtime` replaces platform-branched `stat` calls; gracefully falls back to `date -r` for BusyBox/Alpine.
- README — added platform-support matrix, WSL2/Windows sections, Problem/Why sections, prominent donation button.
- `uninstall.sh` now also removes `~/.claude/.usage-cache.json`.

### Fixed
- Windows (Git Bash / MSYS2): `powershell.exe` output now has trailing `\r` stripped so the JSON parses cleanly.
- First-run cold-start on macOS and Windows: no longer shows empty line 3 until 2 minutes pass.
- `.idea/*` IDE files no longer get tracked.

## [1.0.0] — 2026-03-02

Initial public release.

### Added
- Three-line status bar: model, context bar, tokens, cache, cost, duration, lines, git branch, directory, vim mode, agent, 200K warning, 5h/7d usage limits.
- Context compaction counter (`#N`), reset on new session (>5 min gap + low tokens).
- Context threshold flag files at 70% / 85% / 95% under `~/.claude/.context-flags/`.
- macOS native notifications at 85% and 95% via `osascript`.
- 20-character progress bar with color thresholds (green → yellow → red).
- 10-character fuel-gauge bars for 5h / 7d subscription quota with ETA reset countdown.
- OAuth usage fetch from `https://api.anthropic.com/api/oauth/usage` with 2-minute cache and background refresh.
- `install.sh` and `uninstall.sh`.
- README, LICENSE (MIT), sample input fixture.
- PayPal donation badge and `.github/FUNDING.yml`.

### Linux-specific fixes (PR #1, odlev)
- Fallback to `~/.claude/.credentials.json` when `secret-tool` fails (Claude Code does not write to Linux keyring).
- Synchronous refresh on Linux (Claude Code kills backgrounded child processes on exit).
- Cold-start now triggers when cache file is missing, not only when empty.

[1.3.0]: https://github.com/vbcherepanov/claude-statusbar/compare/v1.1.0...v1.3.0
[1.1.0]: https://github.com/vbcherepanov/claude-statusbar/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/vbcherepanov/claude-statusbar/releases/tag/v1.0.0
