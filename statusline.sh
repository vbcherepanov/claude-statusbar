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

STATUSLINE_VERSION="1.4.0"

# === Limits: endpoints, cache files and timings ===
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
USAGE_API_BETA="oauth-2025-04-20"
USAGE_CACHE="$HOME/.claude/.usage-cache.json"
USAGE_NEXT_ATTEMPT="$HOME/.claude/.usage-next-attempt"
PLAN_CACHE="$HOME/.claude/.usage-plan"
PROFILE_URL="https://api.anthropic.com/api/oauth/profile"
PLAN_TTL_SECS=3600
PLAN_EXPIRED_STAMP=200001010000
USAGE_TTL_SECS=120
USAGE_FAIL_BACKOFF_SECS=300
USAGE_HTTP_TIMEOUT_SECS=5
USAGE_STALE_SECS=900
LIMIT_BAR_WIDTH=10

# Secondary text uses an explicit 256-color gray: the faint attribute is unreadable in many themes.
MUTED_COLOR_DEFAULT=250
MUTED_COLOR=${STATUSLINE_MUTED_COLOR:-$MUTED_COLOR_DEFAULT}
[[ "$MUTED_COLOR" =~ ^[0-9]+$ ]] && (( MUTED_COLOR <= 255 )) || MUTED_COLOR=$MUTED_COLOR_DEFAULT
D="\033[38;5;${MUTED_COLOR}m"

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
    stat -f %m "$f" 2>/dev/null \
        || stat -c %Y "$f" 2>/dev/null \
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

# True when the epoch stored in the given file has passed (or the file is absent).
_attempt_due() {
    local next=0
    [[ -f "$1" ]] && read -r next < "$1"
    [[ "$next" =~ ^[0-9]+$ ]] || next=0
    (( $(date +%s) >= next ))
}

# Block further attempts for N seconds. Args: state file, seconds.
_defer_attempt() {
    printf '%d' $(( $(date +%s) + $2 )) > "$1"
}

# Replace a file atomically from stdin, readable by the owner only.
_write_atomic() {
    local tmp
    tmp=$(mktemp "$1.XXXXXX") || return 1
    cat > "$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

# Cache the subscription name, e.g. "Ultra" or "Pro"; stdin doesn't carry it. The profile's
# plan_display_name is authoritative: the credential's type and tier can lag behind it
# (an Ultra account can still report "max" and "..._max_20x"). Args: credential JSON, token.
_store_plan() {
    local cred=$1 tk=$2 plan fallback
    [[ ! -s "$PLAN_CACHE" ]] || (( $(date +%s) - $(_stat_mtime "$PLAN_CACHE") >= PLAN_TTL_SECS )) || return 0

    plan=$(printf 'header = "Authorization: Bearer %s"\n' "$tk" | curl -sf -K - \
        --max-time "$USAGE_HTTP_TIMEOUT_SECS" -A "claude-statusline/$STATUSLINE_VERSION" \
        -H "anthropic-beta: $USAGE_API_BETA" "$PROFILE_URL" 2>/dev/null \
        | jq -r '.organization.plan_display_name // empty | gsub("[^A-Za-z0-9 ]"; "")' 2>/dev/null)
    if [[ -n "$plan" ]]; then
        printf '%s\n' "$plan" | _write_atomic "$PLAN_CACHE"
        return
    fi

    # Profile unavailable: keep a known name, otherwise derive one and leave it expired
    # so the next usage request asks the profile again.
    [[ -s "$PLAN_CACHE" ]] && return 0
    fallback=$(printf '%s' "$cred" | jq -r '.claudeAiOauth
        | (.subscriptionType // "" | gsub("[^A-Za-z0-9]"; "")) as $type
        | (.rateLimitTier // "" | (capture("(?<x>[0-9]+x)$").x)? // "") as $multiplier
        | if $type == "" then empty
          else ($type[:1] | ascii_upcase) + $type[1:] + (if $multiplier == "" then "" else " " + $multiplier end)
          end' 2>/dev/null)
    [[ -n "$fallback" ]] || return 0
    printf '%s\n' "$fallback" | _write_atomic "$PLAN_CACHE" && touch -t "$PLAN_EXPIRED_STAMP" "$PLAN_CACHE"
}

# Fetch usage JSON and cache it on success. Every attempt schedules the next one,
# so a failing endpoint is never retried on each render; a 429 honours Retry-After.
_fetch_usage() {
    local cred tk body hdr code delay=$USAGE_FAIL_BACKOFF_SECS retry
    _defer_attempt "$USAGE_NEXT_ATTEMPT" "$USAGE_FAIL_BACKOFF_SECS"
    cred=$(_get_cred)
    [[ -n "$cred" ]] || return 1
    tk=$(printf '%s' "$cred" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [[ -n "$tk" ]] || return 1
    _store_plan "$cred" "$tk"

    body=$(mktemp "${TMPDIR:-/tmp}/statusline-usage.XXXXXX") || return 1
    hdr=$(mktemp "${TMPDIR:-/tmp}/statusline-usage.XXXXXX") || { rm -f "$body"; return 1; }
    # The token goes through stdin so it never shows up in the process list.
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$tk" | curl -s -K - \
        --max-time "$USAGE_HTTP_TIMEOUT_SECS" -o "$body" -D "$hdr" -w '%{http_code}' \
        -A "claude-statusline/$STATUSLINE_VERSION" \
        -H "anthropic-beta: $USAGE_API_BETA" "$USAGE_URL" 2>/dev/null)

    # Windows are optional: some plans have no five_hour, so don't require any single one.
    if [[ "$code" == "200" ]] \
        && jq -e 'type == "object" and (has("limits") or has("five_hour") or has("seven_day"))' "$body" &>/dev/null \
        && _write_atomic "$USAGE_CACHE" < "$body"; then
        _defer_attempt "$USAGE_NEXT_ATTEMPT" "$USAGE_TTL_SECS"
    else
        retry=$(tr -d '\r' < "$hdr" | sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]: *\([0-9][0-9]*\)$/\1/p' | tail -1)
        [[ -n "$retry" ]] && delay=$retry
        (( delay < USAGE_TTL_SECS )) && delay=$USAGE_TTL_SECS
        _defer_attempt "$USAGE_NEXT_ATTEMPT" "$delay"
    fi
    rm -f "$body" "$hdr"
}

# Format seconds until a reset: 300 → "5m", 9660 → "2h41m", 158400 → "1d20h"
_fmt_left() {
    local s=$1 d h m
    d=$((s / 86400)) h=$(((s % 86400) / 3600)) m=$(((s % 3600) / 60))
    if (( d > 0 )); then printf '%dd%dh' "$d" "$h"
    elif (( h > 0 )); then printf '%dh%02dm' "$h" "$m"
    else printf '%dm' "$m"
    fi
}

# Render one limit as "label [bar] left% ↻reset" into LIMIT_SEGMENT (fuel gauge: full=good).
# Args: label, used percent, reset epoch (0 = unknown), "stale" to mark old data.
_limit_segment() {
    local label=$1 used=$2 reset=$3 stale=$4 rem filled color bar='' i left=''
    rem=$((100 - used))
    (( rem < 0 )) && rem=0
    (( rem > 100 )) && rem=100
    filled=$((rem * LIMIT_BAR_WIDTH / 100))
    if (( rem > 50 )); then color='\033[32m'; elif (( rem > 20 )); then color='\033[33m'; else color='\033[31m'; fi
    for ((i=0; i<filled; i++)); do bar+='█'; done
    for ((i=filled; i<LIMIT_BAR_WIDTH; i++)); do bar+='░'; done
    (( reset > NOW_EPOCH )) && left=" ${D}↻$(_fmt_left $((reset - NOW_EPOCH)))${R}"
    LIMIT_SEGMENT="${D}${label}${R} [${color}${bar}${R}] ${color}${stale:+~}${rem}%${R}${left}"
}

# Join TSV rows (label, used, reset, source) into SEP-separated segments in LIMIT_LINE.
# Rows from a cache older than USAGE_STALE_SECS get a "~" marker. Args: cache file.
_build_limit_line() {
    local cache=$1 label used reset src stale age
    LIMIT_LINE=''
    age=$(( NOW_EPOCH - $(_stat_mtime "$cache") ))
    while IFS=$'\t' read -r label used reset src; do
        [[ -n "$label" ]] || continue
        stale=''
        [[ "$src" == "cache" ]] && (( age > USAGE_STALE_SECS )) && stale=stale
        _limit_segment "$label" "$used" "$reset" "$stale"
        LIMIT_LINE+="${LIMIT_LINE:+$SEP}$LIMIT_SEGMENT"
    done
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
    STATUSLINE_USAGE_LIMITS=0     Disable all usage limit lines and their network calls
    STATUSLINE_MUTED_COLOR=<n>    256-color number for secondary text (default 250)
    STATUSLINE_PLAN=0             Hide the subscription name in the limits line
    STATUSLINE_WINDOW_COUNTER=0   Disable context compaction counter
    STATUSLINE_FLAGS=0            Disable threshold flag files
    STATUSLINE_FLAG_DIR=<dir>     Custom flag directory
    STATUSLINE_GITHUB=0           Disable PR badge in line 2

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
    "CWD="      + (.workspace.current_dir // .cwd // "" | @sh),
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
    "LINES_REMOVED=" + (.cost.total_lines_removed // 0 | tostring | @sh),
    "GH_REPO="      + (.workspace.repo.name // .github.repo // "" | @sh),
    "PR_NUMBER="    + (.pr.number // .github.pr.number // 0 | tostring | @sh),
    "PR_STATE="     + (.pr.review_state // .github.pr.state // "" | @sh),
    "PR_DRAFT="     + (.github.pr.draft // false | tostring | @sh),
    "PR_KIND="      + (.pr.kind // "" | @sh)
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
[[ -n "$CWD" && -d "$CWD" ]] && GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)

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
    WIN_FMT="${D}#${WINDOW_COUNT}\033[0m"
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

# === ANSI shortcuts ===
R='\033[0m' SEP=" ${D}|${R} "

# === Usage limits (subscription quota tracking) ===
# Sources, freshest first:
#  - stdin .rate_limits: documented, no network. Each window may be absent, e.g. plans
#    without a 5-hour limit, so an absent window means there is no such limit.
#  - cached /api/oauth/usage: undocumented, but the only source of per-model limits such as
#    Fable, and the fallback for 5h/7d before the session's first API response.
# Rows are classified by the server's `kind`, never by label. Requires claude.ai OAuth login.
# Set STATUSLINE_USAGE_LIMITS=0 to disable.
#
# Credential source per platform (see _get_cred): macOS Keychain → Windows Credential Manager
# → libsecret (Linux), each with fallback to ~/.claude/.credentials.json.
CLAUDE_LIMITS=''

# jq helpers: label sanitizer, reset parser (epoch or ISO 8601, fraction optional)
# and TSV row builder. Windows whose reset has passed are dropped.
JQ_LIMIT_DEFS='
def clean: tostring | gsub("[\\p{Cc}\\\\]"; "");
def offset_secs:
    if . == "Z" then 0
    else capture("^(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")
        | ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "-" then -1 else 1 end)
    end;
def epoch:
    if type == "number" then floor
    elif type == "string" then
        try (capture("^(?<d>[0-9T:-]+?)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
            | (.d + "Z" | fromdate) - (.z // "Z" | offset_secs))
        catch null
    else null end;
def row($label; $used; $reset; $src):
    if ($used | type) == "number"
    then {label: ($label | clean), used: ($used | floor), reset: (($reset | epoch) // 0), src: $src}
    else empty end;
def emit($now): select(.reset == 0 or .reset > $now) | [.label, .used, .reset, .src] | @tsv;
'

if [[ "${STATUSLINE_USAGE_LIMITS:-1}" != "0" ]]; then
    : "${NOW_EPOCH:=$(date +%s)}"

    # No cache yet: fetch sync so the first render has data.
    # Otherwise background on macOS/Windows (child survives parent exit),
    # sync on Linux/WSL (Claude Code kills child processes on exit).
    if _attempt_due "$USAGE_NEXT_ATTEMPT"; then
        _os=$(_detect_os)
        if [[ ! -s "$USAGE_CACHE" || ( "$_os" != "mac" && "$_os" != "windows" ) ]]; then
            _fetch_usage 2>/dev/null || true
        else
            _defer_attempt "$USAGE_NEXT_ATTEMPT" "$USAGE_TTL_SECS"
            ( _fetch_usage ) &>/dev/null &
        fi
    fi

    _cached=$(jq -c . "$USAGE_CACHE" 2>/dev/null)
    _build_limit_line "$USAGE_CACHE" < <(printf '%s\n%s\n' "$input" "${_cached:-null}" | jq -rs --argjson now "$NOW_EPOCH" "$JQ_LIMIT_DEFS"'
        (.[0].rate_limits // {}) as $live | (.[1] // {}) as $c |
        def scope_label:
            .scope.model.display_name
            // (.scope.surface | if type == "object" then .display_name elif type == "string" then . else null end)
            // .kind;
        [row("5h"; $live.five_hour.used_percentage; $live.five_hour.resets_at; "live"),
         row("7d"; $live.seven_day.used_percentage; $live.seven_day.resets_at; "live")] as $live_rows |
        (($c.limits // []) | map(select(type == "object"))) as $meters |
        (if ($meters | length) > 0 then
            [$meters[] | select(.kind == "session") | row("5h"; .percent; .resets_at; "cache")]
            + [$meters[] | select(.kind == "weekly_all") | row("7d"; .percent; .resets_at; "cache")]
        else
            [row("5h"; $c.five_hour.utilization; $c.five_hour.resets_at; "cache"),
             row("7d"; $c.seven_day.utilization; $c.seven_day.resets_at; "cache")]
        end) as $cached_rows |
        (if ($meters | length) > 0 then
            [$meters[] | select(.kind != "session" and .kind != "weekly_all")
                | row(scope_label; .percent; .resets_at; "cache")]
        else
            [row("Opus"; $c.seven_day_opus.utilization; $c.seven_day_opus.resets_at; "cache"),
             row("Sonnet"; $c.seven_day_sonnet.utilization; $c.seven_day_sonnet.resets_at; "cache")]
        end) as $model_rows |
        (if ($live_rows | length) > 0 then $live_rows else $cached_rows end)
        + $model_rows
        + [row("spend"; $live.spend_limit.used_percentage; $live.spend_limit.resets_at; "live")]
        | .[] | emit($now)
    ' 2>/dev/null)
    CLAUDE_LIMITS=$LIMIT_LINE

    if [[ "${STATUSLINE_PLAN:-1}" != "0" && -s "$PLAN_CACHE" ]]; then
        read -r _plan < "$PLAN_CACHE"
        [[ -n "$_plan" ]] && CLAUDE_LIMITS="\033[36m${_plan}${R}${CLAUDE_LIMITS:+$SEP$CLAUDE_LIMITS}"
    fi

fi

# === Line 1: Model | Context bar % of size #window | Tokens in/out | Cache ===
if [[ -n "$WIN_FMT" ]]; then
    printf '\033[1m\033[36m%s\033[0m%b[%b%s%b] %d%% of %s %b%b\033[32m↓%s\033[0m \033[35m↑%s\033[0m%b%bcache%b r:%s w:%s\n' \
        "$MODEL" "$SEP" "$C_CTX" "$BAR" "$R" "$PCT" "$CTX_SIZE_FMT" "$WIN_FMT" "$SEP" \
        "$IN_FMT" "$OUT_FMT" "$SEP" "$D" "$R" "$CACHE_R_FMT" "$CACHE_C_FMT"
else
    printf '\033[1m\033[36m%s\033[0m%b[%b%s%b] %d%% of %s%b\033[32m↓%s\033[0m \033[35m↑%s\033[0m%b%bcache%b r:%s w:%s\n' \
        "$MODEL" "$SEP" "$C_CTX" "$BAR" "$R" "$PCT" "$CTX_SIZE_FMT" "$SEP" \
        "$IN_FMT" "$OUT_FMT" "$SEP" "$D" "$R" "$CACHE_R_FMT" "$CACHE_C_FMT"
fi

# === Line 2: Cost | Duration | Lines | Git | Dir | extras ===
L2=$(printf '\033[33m%s\033[0m%b\033[94m⏱ %s\033[0m %b(api %s)%b%b\033[32m+%s\033[0m/\033[31m-%s\033[0m' \
    "$COST_FMT" "$SEP" "$DURATION_FMT" "$D" "$API_DUR_FMT" "$R" "$SEP" "$LINES_ADDED" "$LINES_REMOVED")

[[ -n "$GIT_BRANCH" ]] && L2+=$(printf '%b\033[35m⎇ %s\033[0m' "$SEP" "$GIT_BRANCH")
[[ -n "$DIR_NAME" ]]   && L2+=$(printf '%b%b📂 %s%b' "$SEP" "$D" "$DIR_NAME" "$R")

# === PR badge (documented stdin fields .pr.* and .workspace.repo; .github.* is the older shape) ===
# 🟢 open/pending | ✅ approved | 🔴 changes requested | 🟡 draft | 🟣 merged | ⚫ closed
# | "· no PR" when the repo is known but the branch has no open PR. GitLab shows MR#N.
# Set STATUSLINE_GITHUB=0 to hide the block.
if [[ "${STATUSLINE_GITHUB:-1}" != "0" && -n "$GH_REPO" ]]; then
    if (( ${PR_NUMBER:-0} > 0 )); then
        [[ "$PR_DRAFT" == "true" ]] && PR_STATE=draft
        case "$PR_STATE" in
            draft)             PR_ICON='🟡' PR_COLOR='\033[33m' ;;
            approved)          PR_ICON='✅' PR_COLOR='\033[32m' ;;
            changes_requested) PR_ICON='🔴' PR_COLOR='\033[31m' ;;
            merged)            PR_ICON='🟣' PR_COLOR='\033[35m' ;;
            closed)            PR_ICON='⚫' PR_COLOR='\033[31m' ;;
            open|pending|'')   PR_ICON='🟢' PR_COLOR='\033[32m' ;;
            *)                 PR_ICON='⚪' PR_COLOR=$D ;;
        esac
        PR_PREFIX='PR'
        [[ "$PR_KIND" == "mr" ]] && PR_PREFIX='MR'
        L2+=$(printf '%b%b%s %s#%d%b' "$SEP" "$PR_COLOR" "$PR_ICON" "$PR_PREFIX" "$PR_NUMBER" "$R")
    else
        L2+=$(printf '%b%b· no PR%b' "$SEP" "$D" "$R")
    fi
fi

[[ -n "$VIM_MODE" ]]   && { [[ "$VIM_MODE" == "NORMAL" ]] && L2+=$(printf '%b\033[34m[N]\033[0m' "$SEP") || L2+=$(printf '%b\033[32m[I]\033[0m' "$SEP"); }
[[ -n "$AGENT_NAME" ]] && L2+=$(printf '%b\033[36m🤖 %s\033[0m' "$SEP" "$AGENT_NAME")
[[ "$EXCEEDS_200K" == "true" ]] && L2+=$(printf ' \033[31m⚠ >200K\033[0m')

printf '%b\n' "$L2"

# === Line 3: Subscription name and Claude limits (only the windows this plan has, plus per-model ones like Fable) ===
[[ -n "$CLAUDE_LIMITS" ]] && printf '%b\n' "$CLAUDE_LIMITS"

exit 0
