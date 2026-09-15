#!/bin/bash
# claude-statusline — Rich status line for Claude Code CLI
# https://github.com/vbcherepanov/claude-statusbar
#
# Displays real-time session metrics: model, context usage, tokens,
# cost, duration, git branch, cache stats, usage limits, and more.
#
# Claude Code pipes JSON to stdin with session data.
# This script parses it and outputs a formatted three-line status bar.
#
# Supported platforms: macOS, Linux, WSL2, Windows (Git Bash / MSYS2 / Cygwin).

STATUSLINE_VERSION="1.1.0"

# === Platform detection and cross-platform helpers ===

# Detect OS family: "mac" | "linux" | "wsl" | "windows" | "unknown"
_detect_os() {
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

# Cross-platform file mtime in epoch seconds (works on BSD stat / GNU stat / busybox)
_stat_mtime() {
    local f=$1
    [[ -f "$f" ]] || { printf '0'; return; }
    stat -c %Y "$f" 2>/dev/null \
        || stat -f %m "$f" 2>/dev/null \
        || date -r "$f" +%s 2>/dev/null \
        || printf '0'
}

# Read OAuth credential JSON.
# Tries platform-native secure storage first, falls back to ~/.claude/.credentials.json
# (Claude Code stores token in the file on Linux; on macOS/Windows it's a belt-and-braces fallback).
_get_cred() {
    local cred="" os
    os=$(_detect_os)
    case "$os" in
        mac)
            cred=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            ;;
        windows)
            cred=$(powershell.exe -NoProfile -Command \
                '[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((Get-StoredCredential -Target "Claude Code-credentials" -AsCredentialObject).Password))' 2>/dev/null | tr -d '\r')
            ;;
        linux|wsl)
            cred=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
            ;;
    esac
    # Universal fallback: plain credentials file (perms 600, Claude Code writes it on Linux by default)
    if [[ -z "$cred" && -f "$HOME/.claude/.credentials.json" ]]; then
        cred=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null)
    fi
    printf '%s' "$cred"
}

# Fetch usage JSON and write to cache on success. Silent on failure.
_fetch_usage() {
    local cred tk data
    cred=$(_get_cred)
    [[ -n "$cred" ]] || return 1
    tk=$(printf '%s' "$cred" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [[ -n "$tk" ]] || return 1
    data=$(curl -sf --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $tk" \
        -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
    [[ -n "$data" ]] || return 1
    printf '%s' "$data" | jq -e '.five_hour' &>/dev/null || return 1
    umask 077
    printf '%s' "$data" > "$USAGE_CACHE"
    touch "$USAGE_CACHE"
}

# Platform-aware notification. Silent if no notifier available.
# Args: title, message, [level: critical|warning|info]
_notify() {
    local title=$1 msg=$2 level=${3:-info}
    case "$(_detect_os)" in
        mac)
            local sound=''
            case "$level" in
                critical) sound='Sosumi' ;;
                warning)  sound='Glass' ;;
            esac
            if [[ -n "$sound" ]]; then
                osascript -e "display notification \"$msg\" with title \"$title\" sound name \"$sound\"" &>/dev/null &
            else
                osascript -e "display notification \"$msg\" with title \"$title\"" &>/dev/null &
            fi
            ;;
        linux|wsl)
            if command -v notify-send &>/dev/null; then
                local urgency=normal
                [[ "$level" == "critical" ]] && urgency=critical
                notify-send -u "$urgency" "$title" "$msg" &>/dev/null &
            fi
            ;;
        windows)
            # BurntToast is optional; silent no-op if module missing
            if command -v powershell.exe &>/dev/null; then
                powershell.exe -NoProfile -Command \
                    "if (Get-Module -ListAvailable -Name BurntToast) { Import-Module BurntToast; New-BurntToastNotification -Text '$title','$msg' }" &>/dev/null &
            fi
            ;;
    esac
}

# === CLI flags (handled before `cat` which blocks on stdin) ===
case "${1:-}" in
    --version|-v)
        printf 'claude-statusline %s\n' "$STATUSLINE_VERSION"
        exit 0
        ;;
    --help|-h)
        cat <<EOF
claude-statusline $STATUSLINE_VERSION — status line for Claude Code CLI

Usage: piped from Claude Code (configured in ~/.claude/settings.json)
       cat examples/sample-input.json | bash statusline.sh   # smoke test

Flags:
    --version, -v    Show version
    --help, -h       Show this help

Environment:
    STATUSLINE_USAGE_LIMITS=0     Disable 5h/7d usage limits line
    STATUSLINE_WINDOW_COUNTER=0   Disable context compaction counter
    STATUSLINE_FLAGS=0            Disable threshold flag files
    STATUSLINE_FLAG_DIR=<dir>     Custom flag directory

Home: https://github.com/vbcherepanov/claude-statusbar
EOF
        exit 0
        ;;
esac

input=$(cat)

# === Parse all fields from JSON in a single jq call ===
# Uses @sh for safe shell escaping (compatible with macOS bash 3.2+)
eval "$(echo "$input" | jq -r '
    "MODEL="    + (.model.display_name // "Unknown" | @sh),
    "EFFORT="   + (.effort.level // "" | @sh),
    "CWD="      + (.cwd // "" | @sh),
    "VIM_MODE=" + (.vim.mode // "" | @sh),
    "AGENT_NAME=" + (.agent.name // "" | @sh),
    "EXCEEDS_200K=" + (.exceeds_200k_tokens // false | tostring | @sh),
    "PCT_RAW="  + (.context_window.used_percentage // 0 | tostring | @sh),
    "INPUT_TOKENS=" + (.context_window.total_input_tokens // 0 | tostring | @sh),
    "OUTPUT_TOKENS=" + (.context_window.total_output_tokens // 0 | tostring | @sh),
    "CTX_SIZE="     + (.context_window.context_window_size // 0 | tostring | @sh),
    "CACHE_CREATE=" + (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring | @sh),
    "CACHE_READ="   + (.context_window.current_usage.cache_read_input_tokens // 0 | tostring | @sh),
    "COST="         + (.cost.total_cost_usd // 0 | tostring | @sh),
    "DURATION_MS="  + (.cost.total_duration_ms // 0 | tostring | @sh),
    "API_DURATION_MS=" + (.cost.total_api_duration_ms // 0 | tostring | @sh),
    "LINES_ADDED="  + (.cost.total_lines_added // 0 | tostring | @sh),
    "LINES_REMOVED=" + (.cost.total_lines_removed // 0 | tostring | @sh)
')"

# === Formatting helpers (pure bash, no subshells) ===

# Format token count: 1500 → "1.5K", 2300000 → "2.3M"
fmt_tokens() {
    local t=${1%%.*}; : "${t:=0}"
    if (( t >= 1000000 )); then
        printf '%d.%dM' $((t / 1000000)) $(( (t % 1000000) / 100000 ))
    elif (( t >= 1000 )); then
        printf '%d.%dK' $((t / 1000)) $(( (t % 1000) / 100 ))
    else
        printf '%s' "$t"
    fi
}

# Format milliseconds: 65000 → "1m05s", 3700000 → "1h01m"
fmt_duration() {
    local ms=${1%%.*}; : "${ms:=0}"
    (( ms <= 0 )) && { printf '0s'; return; }
    local h=$((ms / 3600000)) m=$(( (ms / 60000) % 60 )) s=$((ms / 1000 % 60))
    if (( h > 0 )); then printf '%dh%02dm' "$h" "$m"
    elif (( m > 0 )); then printf '%dm%02ds' "$m" "$s"
    else printf '%ds' "$s"
    fi
}

# === Compute formatted values ===
PCT=${PCT_RAW%%.*}; : "${PCT:=0}"

IN_FMT=$(fmt_tokens "$INPUT_TOKENS")
OUT_FMT=$(fmt_tokens "$OUTPUT_TOKENS")
CACHE_R_FMT=$(fmt_tokens "$CACHE_READ")
CACHE_C_FMT=$(fmt_tokens "$CACHE_CREATE")
CTX_SIZE_FMT=$(fmt_tokens "$CTX_SIZE")
DURATION_FMT=$(fmt_duration "$DURATION_MS")
API_DUR_FMT=$(fmt_duration "$API_DURATION_MS")

# Cost formatting (pure bash, no bc/awk)
COST_INT=${COST%%.*}; : "${COST_INT:=0}"
COST_DEC=${COST#*.}
[[ "$COST_DEC" == "$COST" ]] && COST_DEC="00"
COST_DEC="${COST_DEC}00"; COST_DEC=${COST_DEC:0:2}
COST_FMT="\$${COST_INT}.${COST_DEC}"

# Progress bar — 20-char wide block bar
BAR=""; FILLED=$((PCT * 20 / 100))
for ((i=0; i<FILLED; i++)); do BAR+='█'; done
for ((i=FILLED; i<20; i++)); do BAR+='░'; done

# Context usage color: green → yellow → red
if (( PCT >= 90 )); then C_CTX='\033[31m'   # red
elif (( PCT >= 70 )); then C_CTX='\033[33m'  # yellow
else C_CTX='\033[32m'                         # green
fi

# Git branch (only if inside a repo)
GIT_BRANCH=""
[[ -n "$CWD" && -d "$CWD/.git" ]] && GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)

# Working directory name
DIR_NAME="${CWD##*/}"

# === Window counter (context compaction tracking) ===
# Tracks how many times the context window has been compacted during a session.
# Detects compaction when input tokens drop below 40% of peak.
# Resets on new session (>5min gap + low tokens).
# Set STATUSLINE_WINDOW_COUNTER=0 to disable.
FLAG_DIR="${STATUSLINE_FLAG_DIR:-$HOME/.claude/.context-flags}"
WINDOW_COUNT=1
WIN_FMT=""

if [[ "${STATUSLINE_WINDOW_COUNTER:-1}" != "0" ]]; then
    [[ -d "$FLAG_DIR" ]] || mkdir -p "$FLAG_DIR"
    WINDOW_STATE="$FLAG_DIR/window-state"
    CUR_T=${INPUT_TOKENS%%.*}; : "${CUR_T:=0}"
    NOW_EPOCH=$(date +%s)

    if [[ -f "$WINDOW_STATE" ]]; then
        read -r W_COUNT W_PEAK W_EPOCH < "$WINDOW_STATE"
        : "${W_COUNT:=1}" "${W_PEAK:=0}" "${W_EPOCH:=0}"
        if (( NOW_EPOCH - W_EPOCH > 300 && CUR_T < 5000 )); then
            WINDOW_COUNT=1; W_PEAK=$CUR_T
        elif (( W_PEAK > 30000 && CUR_T < W_PEAK * 4 / 10 )); then
            WINDOW_COUNT=$((W_COUNT + 1)); W_PEAK=$CUR_T
        else
            WINDOW_COUNT=$W_COUNT
            (( CUR_T > W_PEAK )) && W_PEAK=$CUR_T
        fi
    else
        W_PEAK=$CUR_T
    fi
    printf '%d %d %d' "$WINDOW_COUNT" "$W_PEAK" "$NOW_EPOCH" > "$WINDOW_STATE"
    WIN_FMT="\033[2m#${WINDOW_COUNT}\033[0m"
fi

# === Optional: Context threshold flags ===
# Writes flag files when context usage crosses 70/85/95%.
# Useful for hooks that trigger auto-save or notifications.
# Set STATUSLINE_FLAGS=0 to disable this feature.
if [[ "${STATUSLINE_FLAGS:-1}" != "0" ]] && (( PCT >= 70 )); then
    [[ -d "$FLAG_DIR" ]] || mkdir -p "$FLAG_DIR"
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if (( PCT >= 95 )) && [[ ! -f "$FLAG_DIR/threshold-95" ]]; then
        printf '{"pct":%d,"in":"%s","out":"%s","cost":"%s","dur":"%s","cwd":"%s","t":"%s"}' \
            "$PCT" "$IN_FMT" "$OUT_FMT" "$COST_FMT" "$DURATION_FMT" "$CWD" "$NOW" > "$FLAG_DIR/threshold-95"
        _notify "Claude Code | CRITICAL" "Context at ${PCT}%! Auto-saving..." critical
    elif (( PCT >= 85 )) && [[ ! -f "$FLAG_DIR/threshold-85" ]]; then
        printf '{"pct":%d,"in":"%s","out":"%s","cost":"%s","dur":"%s","cwd":"%s","t":"%s"}' \
            "$PCT" "$IN_FMT" "$OUT_FMT" "$COST_FMT" "$DURATION_FMT" "$CWD" "$NOW" > "$FLAG_DIR/threshold-85"
        _notify "Claude Code | WARNING" "Context at ${PCT}%! Consider saving." warning
    elif (( PCT >= 70 )) && [[ ! -f "$FLAG_DIR/threshold-70" ]]; then
        printf '{"pct":%d,"t":"%s"}' "$PCT" "$NOW" > "$FLAG_DIR/threshold-70"
    fi
elif [[ "${STATUSLINE_FLAGS:-1}" != "0" ]] && (( PCT < 10 )); then
    FLAG_DIR="${STATUSLINE_FLAG_DIR:-$HOME/.claude/.context-flags}"
    [[ -d "$FLAG_DIR" ]] && rm -f "$FLAG_DIR"/threshold-* 2>/dev/null
fi

# === Usage limits (subscription quota tracking) ===
# Fetches 5-hour and 7-day usage limits from Anthropic OAuth API.
# Cached for 2 minutes to avoid rate limiting.
# Requires claude.ai OAuth login (not API key).
# Set STATUSLINE_USAGE_LIMITS=0 to disable.
#
# Credential source per platform (see _get_cred): macOS Keychain → Windows Credential Manager
# → libsecret (Linux), each with fallback to ~/.claude/.credentials.json.
USAGE_CACHE="$HOME/.claude/.usage-cache.json"
HAS_USAGE=0

if [[ "${STATUSLINE_USAGE_LIMITS:-1}" != "0" ]]; then
    : "${NOW_EPOCH:=$(date +%s)}"
    _cache_mtime=$(_stat_mtime "$USAGE_CACHE")
    _cache_size=0
    [[ -f "$USAGE_CACHE" ]] && _cache_size=$(wc -c < "$USAGE_CACHE" 2>/dev/null || echo 0)

    # Cold start: no cache or empty — must fetch sync so user sees data on first run.
    # Warm refresh: background on macOS/Windows (child survives parent exit),
    #               sync on Linux/WSL (Claude Code kills child processes on exit).
    _is_cold=0
    [[ ! -f "$USAGE_CACHE" ]] && _is_cold=1
    (( _cache_size <= 2 )) && _is_cold=1
    if (( _is_cold )) || (( NOW_EPOCH - _cache_mtime > 120 )); then
        _os=$(_detect_os)
        if (( _is_cold )); then
            _fetch_usage 2>/dev/null || true
        elif [[ "$_os" == "mac" || "$_os" == "windows" ]]; then
            ( _fetch_usage ) &>/dev/null &
        else
            _fetch_usage 2>/dev/null || true
        fi
    fi

    # Read cached data and compute remaining % and reset times
    if [[ -f "$USAGE_CACHE" ]]; then
        eval "$(jq -r --argjson now "$NOW_EPOCH" '
            "U5H_USED=" + (.five_hour.utilization // 0 | floor | tostring | @sh),
            "U7D_USED=" + (.seven_day.utilization // 0 | floor | tostring | @sh),
            "U5H_LEFT=" + ((.five_hour.resets_at // "" | if . == "" or . == "null" then 0 else ((split(".")[0] + "Z" | fromdate) - $now | if . < 0 then 0 else . end) end) | tostring | @sh),
            "U7D_LEFT=" + ((.seven_day.resets_at // "" | if . == "" or . == "null" then 0 else ((split(".")[0] + "Z" | fromdate) - $now | if . < 0 then 0 else . end) end) | tostring | @sh)
        ' "$USAGE_CACHE" 2>/dev/null)"
        : "${U5H_USED:=0}" "${U7D_USED:=0}" "${U5H_LEFT:=0}" "${U7D_LEFT:=0}"
        U5H_REM=$(( 100 - U5H_USED )); (( U5H_REM < 0 )) && U5H_REM=0
        U7D_REM=$(( 100 - U7D_USED )); (( U7D_REM < 0 )) && U7D_REM=0

        # 5h bar (10 chars, fuel gauge: full=good, empty=danger)
        _f=$((U5H_REM * 10 / 100)); (( _f > 10 )) && _f=10; (( _f < 0 )) && _f=0; _e=$((10 - _f))
        if (( U5H_REM > 50 )); then C5='\033[32m'; elif (( U5H_REM > 20 )); then C5='\033[33m'; else C5='\033[31m'; fi
        B5="$C5"; for ((i=0;i<_f;i++)); do B5+='█'; done; for ((i=0;i<_e;i++)); do B5+='░'; done; B5+='\033[0m'

        # 7d bar (10 chars)
        _f=$((U7D_REM * 10 / 100)); (( _f > 10 )) && _f=10; (( _f < 0 )) && _f=0; _e=$((10 - _f))
        if (( U7D_REM > 50 )); then C7='\033[32m'; elif (( U7D_REM > 20 )); then C7='\033[33m'; else C7='\033[31m'; fi
        B7="$C7"; for ((i=0;i<_f;i++)); do B7+='█'; done; for ((i=0;i<_e;i++)); do B7+='░'; done; B7+='\033[0m'

        # Format 5h reset time (pure bash)
        _s=${U5H_LEFT%%.*}; : "${_s:=0}"
        _h=$((_s/3600)) _m=$(((_s%3600)/60))
        if (( _h > 0 )); then T5H="${_h}h$(printf '%02d' $_m)m"; else T5H="${_m}m"; fi

        # Format 7d reset time (pure bash, supports days)
        _s=${U7D_LEFT%%.*}; : "${_s:=0}"
        _d=$((_s/86400)) _h=$(((_s%86400)/3600)) _m=$(((_s%3600)/60))
        if (( _d > 0 )); then T7D="${_d}d${_h}h"
        elif (( _h > 0 )); then T7D="${_h}h$(printf '%02d' $_m)m"
        else T7D="${_m}m"; fi

        HAS_USAGE=1
    fi
fi

# === ANSI shortcuts ===
R='\033[0m' D='\033[2m' SEP=" ${D}|${R} "

# Effort suffix - color by level (low=green, medium=yellow, high=red, xhigh=bright red, max=bold red)
EFFORT_FMT=""
if [[ -n "$EFFORT" ]]; then
    case "$EFFORT" in
        low)      C_EFF='\033[32m' ;;
        medium)   C_EFF='\033[33m' ;;
        high)     C_EFF='\033[31m' ;;
        xhigh)    C_EFF='\033[91m' ;;
        max)      C_EFF='\033[1;31m' ;;
        *)        C_EFF='\033[36m' ;;
    esac
    EFFORT_FMT=$(printf ' %b%s\033[0m' "$C_EFF" "$EFFORT")
fi

# === Line 1: Model Effort | Context bar % of size #window | Tokens in/out | Cache ===
if [[ -n "$WIN_FMT" ]]; then
    printf '\033[1m\033[36m%s\033[0m%b%b[%b%s%b] %d%% of %s %b%b\033[32m↓%s\033[0m \033[35m↑%s\033[0m%b%bcache%b r:%s w:%s\n' \
        "$MODEL" "$EFFORT_FMT" "$SEP" "$C_CTX" "$BAR" "$R" "$PCT" "$CTX_SIZE_FMT" "$WIN_FMT" "$SEP" \
        "$IN_FMT" "$OUT_FMT" "$SEP" "$D" "$R" "$CACHE_R_FMT" "$CACHE_C_FMT"
else
    printf '\033[1m\033[36m%s\033[0m%b%b[%b%s%b] %d%% of %s%b\033[32m↓%s\033[0m \033[35m↑%s\033[0m%b%bcache%b r:%s w:%s\n' \
        "$MODEL" "$EFFORT_FMT" "$SEP" "$C_CTX" "$BAR" "$R" "$PCT" "$CTX_SIZE_FMT" "$SEP" \
        "$IN_FMT" "$OUT_FMT" "$SEP" "$D" "$R" "$CACHE_R_FMT" "$CACHE_C_FMT"
fi

# === Line 2: Cost | Duration | Lines | Git | Dir | extras ===
L2=$(printf '\033[33m%s\033[0m%b\033[34m⏱ %s\033[0m %b(api %s)%b%b\033[32m+%s\033[0m/\033[31m-%s\033[0m' \
    "$COST_FMT" "$SEP" "$DURATION_FMT" "$D" "$API_DUR_FMT" "$R" "$SEP" "$LINES_ADDED" "$LINES_REMOVED")

[[ -n "$GIT_BRANCH" ]] && L2+=$(printf '%b\033[35m⎇ %s\033[0m' "$SEP" "$GIT_BRANCH")
[[ -n "$DIR_NAME" ]]   && L2+=$(printf '%b%b📂 %s%b' "$SEP" "$D" "$DIR_NAME" "$R")
[[ -n "$VIM_MODE" ]]   && { [[ "$VIM_MODE" == "NORMAL" ]] && L2+=$(printf '%b\033[34m[N]\033[0m' "$SEP") || L2+=$(printf '%b\033[32m[I]\033[0m' "$SEP"); }
[[ -n "$AGENT_NAME" ]] && L2+=$(printf '%b\033[36m🤖 %s\033[0m' "$SEP" "$AGENT_NAME")
[[ "$EXCEEDS_200K" == "true" ]] && L2+=$(printf ' \033[31m⚠ >200K\033[0m')

printf '%b\n' "$L2"

# === Line 3: Usage limits (5h + 7d with progress bars and reset countdown) ===
if (( HAS_USAGE )); then
    printf '%b5h%b [%b] %b%d%%%b %b↻%s%b%b%b7d%b [%b] %b%d%%%b %b↻%s%b\n' \
        "$D" "$R" "$B5" "$C5" "$U5H_REM" "$R" "$D" "$T5H" "$R" \
        "$SEP" "$D" "$R" "$B7" "$C7" "$U7D_REM" "$R" "$D" "$T7D" "$R"
fi
