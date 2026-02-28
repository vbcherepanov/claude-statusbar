#!/bin/bash
# claude-statusline uninstaller
# Removes statusline.sh and cleans settings.json

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline.sh"
FLAG_DIR="$CLAUDE_DIR/.context-flags"

GREEN='\033[32m' YELLOW='\033[33m' R='\033[0m'

info() { printf "${GREEN}[✓]${R} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${R} %s\n" "$1"; }

echo ""
echo "claude-statusline uninstaller"
echo "─────────────────────────────"
echo ""

# Remove statusline.sh
if [[ -f "$TARGET" ]]; then
    rm "$TARGET"
    info "Removed $TARGET"
else
    warn "statusline.sh not found at $TARGET"
fi

# Remove statusLine from settings.json
if [[ -f "$SETTINGS_FILE" ]] && jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
    TMP=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS_FILE" > "$TMP"
    mv "$TMP" "$SETTINGS_FILE"
    info "Removed statusLine from settings.json"
fi

# Clean up flag files
if [[ -d "$FLAG_DIR" ]]; then
    rm -rf "$FLAG_DIR"
    info "Removed context flag directory"
fi

echo ""
info "Uninstalled. Restart Claude Code to apply."
echo ""
