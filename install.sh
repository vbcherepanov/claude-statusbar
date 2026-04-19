#!/bin/bash
# claude-statusline installer
# Copies statusline.sh to ~/.claude/ and configures settings.json
# Supports: macOS, Linux, WSL2, Windows (Git Bash / MSYS2 / Cygwin)

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

# Detect OS family: "mac" | "linux" | "wsl" | "windows" | "unknown"
detect_os() {
    case "$OSTYPE" in
        darwin*)             printf 'mac' ;;
        msys*|cygwin*|win*)  printf 'windows' ;;
        linux*)
            if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
                printf 'wsl'
            else
                printf 'linux'
            fi
            ;;
        *)                   printf 'unknown' ;;
    esac
}

# Suggest the right install command for a missing dependency
suggest_install() {
    local pkg=$1
    case "$(detect_os)" in
        mac)       printf 'brew install %s' "$pkg" ;;
        linux|wsl)
            if   command -v apt-get   &>/dev/null; then printf 'sudo apt-get install -y %s' "$pkg"
            elif command -v dnf       &>/dev/null; then printf 'sudo dnf install -y %s' "$pkg"
            elif command -v yum       &>/dev/null; then printf 'sudo yum install -y %s' "$pkg"
            elif command -v pacman    &>/dev/null; then printf 'sudo pacman -S --noconfirm %s' "$pkg"
            elif command -v zypper    &>/dev/null; then printf 'sudo zypper install -y %s' "$pkg"
            elif command -v apk       &>/dev/null; then printf 'sudo apk add %s' "$pkg"
            else                                        printf '(install %s via your package manager)' "$pkg"
            fi
            ;;
        windows)   printf 'choco install %s  # or: winget install %s' "$pkg" "$pkg" ;;
        *)         printf '(install %s via your package manager)' "$pkg" ;;
    esac
}

echo ""
printf "${BOLD}claude-statusline installer${R}\n"
echo "─────────────────────────────"
OS=$(detect_os)
printf "Platform: ${BOLD}%s${R}\n" "$OS"
echo ""

# 1. Check dependencies
if ! command -v jq &>/dev/null; then
    error "jq is required. Install: $(suggest_install jq)"
fi
command -v curl &>/dev/null || warn "curl not found — usage limits feature will be disabled"
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

# 5. Platform-specific tips
echo ""
case "$OS" in
    linux)
        if ! command -v notify-send &>/dev/null; then
            warn "notify-send not found — desktop notifications at 85%/95% context will be silent."
            printf "      Install: %s\n" "$(suggest_install libnotify-bin)"
        fi
        if ! command -v secret-tool &>/dev/null; then
            warn "secret-tool not found — will fall back to ~/.claude/.credentials.json (fine)."
            printf "      Optional: %s\n" "$(suggest_install libsecret-tools)"
        fi
        ;;
    wsl)
        warn "WSL2 detected — desktop notifications need a Linux notifier or WSLg."
        printf "      Optional: %s\n" "$(suggest_install libnotify-bin)"
        ;;
    windows)
        warn "Windows (Git Bash / MSYS2) detected — usage limits will read ~/.claude/.credentials.json."
        echo  "      For toast notifications: Install-Module BurntToast -Scope CurrentUser"
        ;;
esac

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
