#!/bin/bash
# claude-statusline installer
# Copies statusline.sh to ~/.claude/ and configures settings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline.sh"

# Colors
GREEN='\033[32m' YELLOW='\033[33m' RED='\033[31m' BOLD='\033[1m' R='\033[0m'

info()  { printf "${GREEN}[✓]${R} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${R} %s\n" "$1"; }
error() { printf "${RED}[✗]${R} %s\n" "$1"; exit 1; }

echo ""
printf "${BOLD}claude-statusline installer${R}\n"
echo "─────────────────────────────"
echo ""

# 1. Check dependencies
command -v jq &>/dev/null || error "jq is required. Install: brew install jq"
command -v claude &>/dev/null || warn "Claude Code CLI not found in PATH (needed at runtime)"

# 2. Create ~/.claude if missing
[[ -d "$CLAUDE_DIR" ]] || mkdir -p "$CLAUDE_DIR"

# 3. Copy statusline.sh
if [[ -f "$TARGET" ]]; then
    warn "Existing statusline.sh found at $TARGET"
    read -rp "  Overwrite? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

cp "$SCRIPT_DIR/statusline.sh" "$TARGET"
chmod +x "$TARGET"
info "Installed statusline.sh → $TARGET"

# 4. Configure settings.json
if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo '{}' > "$SETTINGS_FILE"
    info "Created $SETTINGS_FILE"
fi

# Check if statusLine already configured
if jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
    CURRENT=$(jq -r '.statusLine.command // "none"' "$SETTINGS_FILE")
    if [[ "$CURRENT" == "$TARGET" ]]; then
        info "settings.json already configured"
    else
        warn "statusLine already set to: $CURRENT"
        read -rp "  Replace with $TARGET? [y/N] " answer
        if [[ "$answer" =~ ^[Yy] ]]; then
            TMP=$(mktemp)
            jq --arg cmd "$TARGET" '.statusLine = {"type": "command", "command": $cmd, "padding": 2}' "$SETTINGS_FILE" > "$TMP"
            mv "$TMP" "$SETTINGS_FILE"
            info "Updated statusLine in settings.json"
        fi
    fi
else
    TMP=$(mktemp)
    jq --arg cmd "$TARGET" '.statusLine = {"type": "command", "command": $cmd, "padding": 2}' "$SETTINGS_FILE" > "$TMP"
    mv "$TMP" "$SETTINGS_FILE"
    info "Added statusLine config to settings.json"
fi

echo ""
info "Installation complete! Restart Claude Code to see the status line."
echo ""
echo "  Configuration in ~/.claude/settings.json:"
echo "    \"statusLine\": {"
echo "      \"type\": \"command\","
echo "      \"command\": \"$TARGET\","
echo "      \"padding\": 2"
echo "    }"
echo ""
