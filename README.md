# claude-statusline

A rich, two-line status bar for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI.

Displays real-time session metrics directly in your terminal — model, context usage, tokens, cost, duration, git branch, cache stats, and more.

```
Claude Opus 4.6 | [████████░░░░░░░░░░░░] 42% of 200.0K | ↓156.8K ↑23.4K | cache r:89.0K w:45.0K
$1.47 | ⏱ 5m42s (api 3m18s) | +245/-31 | ⎇ main | 📂 my-project | [N]
```

## Features

- **Model name** — which Claude model is active
- **Context usage bar** — 20-char visual progress bar with color thresholds (green → yellow → red)
- **Token counts** — input/output tokens with human-readable formatting (K/M)
- **Cache stats** — cache read/write token counts
- **Cost** — total session cost in USD
- **Duration** — total time and API time separately
- **Lines changed** — added/removed lines count
- **Git branch** — current branch (when in a repo)
- **Working directory** — project folder name
- **Vim mode** — shows `[N]` or `[I]` indicator when vim mode is active
- **Agent name** — shows active sub-agent name
- **200K warning** — warns when context exceeds 200K tokens
- **Context threshold alerts** — optional flag files at 70/85/95% for hook integration
- **macOS notifications** — optional native alerts at 85% and 95% thresholds

## Requirements

- **jq** — JSON processor (`brew install jq` / `apt install jq`)
- **Claude Code CLI** — v1.0+ with status line support
- **bash** — works with macOS bash 3.2+ and modern bash 4/5

## Installation

### Quick install

```bash
git clone https://github.com/anthropics/claude-statusline.git
cd claude-statusline
bash install.sh
```

The installer will:
1. Copy `statusline.sh` to `~/.claude/statusline.sh`
2. Add the `statusLine` config to `~/.claude/settings.json`
3. Prompt before overwriting existing files

### Manual install

1. Copy the script:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/YOUR_USERNAME/.claude/statusline.sh",
    "padding": 2
  }
}
```

3. Restart Claude Code.

## How It Works

Claude Code pipes a JSON object to stdin on every status update. The JSON contains all session metrics:

```json
{
  "model": { "display_name": "Claude Opus 4.6" },
  "cwd": "/Users/dev/project",
  "vim": { "mode": "NORMAL" },
  "agent": { "name": "" },
  "exceeds_200k_tokens": false,
  "context_window": {
    "used_percentage": 42.5,
    "total_input_tokens": 156800,
    "total_output_tokens": 23400,
    "context_window_size": 200000,
    "current_usage": {
      "cache_creation_input_tokens": 45000,
      "cache_read_input_tokens": 89000
    }
  },
  "cost": {
    "total_cost_usd": 1.47,
    "total_duration_ms": 342000,
    "total_api_duration_ms": 198000,
    "total_lines_added": 245,
    "total_lines_removed": 31
  }
}
```

The script:
1. Parses all 16 fields in a **single `jq` call** using `@sh` for safe eval
2. Formats values with **pure bash** (no subshells, no `bc`, no `awk`)
3. Outputs two ANSI-colored lines

Total execution: **~18ms** on macOS.

## Configuration

### Padding

The `padding` value in settings.json controls vertical space around the status line:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/statusline.sh",
    "padding": 2
  }
}
```

### Context threshold flags

By default, the script writes flag files to `~/.claude/.context-flags/` when context usage crosses 70%, 85%, and 95%. These can be consumed by Claude Code hooks to trigger auto-save or other actions.

Disable this feature:

```bash
# In your shell profile or wrapper
export STATUSLINE_FLAGS=0
```

Custom flag directory:

```bash
export STATUSLINE_FLAG_DIR=/tmp/claude-flags
```

### macOS notifications

At 85% context usage, a "Glass" notification sounds. At 95%, a "Sosumi" alert fires. These use `osascript` and fail silently on Linux.

## Output Layout

### Line 1

```
Model | [████░░░░░░░░] PCT% of SIZE | ↓input ↑output | cache r:READ w:WRITE
```

| Segment | Color | Description |
|---------|-------|-------------|
| Model | Cyan bold | Active model display name |
| Progress bar | Green/Yellow/Red | 20-char block bar based on context % |
| Tokens | Green/Magenta | Input (↓) and output (↑) token counts |
| Cache | Dim | Cache read/write token stats |

### Line 2

```
$COST | ⏱ DURATION (api API_DUR) | +ADDED/-REMOVED | ⎇ BRANCH | 📂 DIR | [N]
```

| Segment | Color | Shown when |
|---------|-------|------------|
| Cost | Yellow | Always |
| Duration | Blue | Always |
| Lines | Green/Red | Always |
| Git branch | Magenta | Inside a git repo |
| Directory | Dim | Always |
| Vim mode | Blue/Green | Vim mode is active |
| Agent | Cyan | Sub-agent is running |
| >200K warning | Red | Tokens exceed 200K |

## Uninstall

```bash
bash uninstall.sh
```

Or manually:

```bash
rm ~/.claude/statusline.sh
# Remove "statusLine" key from ~/.claude/settings.json
```

## Testing

Test with sample data:

```bash
cat examples/sample-input.json | bash statusline.sh
```

## License

MIT
