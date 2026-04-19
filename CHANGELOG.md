# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.1.0]: https://github.com/vbcherepanov/claude-statusbar/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/vbcherepanov/claude-statusbar/releases/tag/v1.0.0
