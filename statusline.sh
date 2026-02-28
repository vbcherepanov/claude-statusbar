#!/bin/bash
# claude-statusline — Rich status line for Claude Code CLI
# https://github.com/vitalii/claude-statusline
#
# Displays real-time session metrics: model, context usage, tokens,
# cost, duration, git branch, cache stats, and more.
#
# Claude Code pipes JSON to stdin with session data.
# This script parses it and outputs a formatted two-line status bar.

input=$(cat)

# === Parse all fields from JSON in a single jq call ===
# Uses @sh for safe shell escaping (compatible with macOS bash 3.2+)
eval "$(echo "$input" | jq -r '
    "MODEL="    + (.model.display_name // "Unknown" | @sh),
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
        # macOS notification (optional, fails silently on Linux)
        osascript -e 'display notification "Context at '"$PCT"'%! Auto-saving..." with title "Claude Code | CRITICAL" sound name "Sosumi"' &>/dev/null &
    elif (( PCT >= 85 )) && [[ ! -f "$FLAG_DIR/threshold-85" ]]; then
        printf '{"pct":%d,"in":"%s","out":"%s","cost":"%s","dur":"%s","cwd":"%s","t":"%s"}' \
            "$PCT" "$IN_FMT" "$OUT_FMT" "$COST_FMT" "$DURATION_FMT" "$CWD" "$NOW" > "$FLAG_DIR/threshold-85"
        osascript -e 'display notification "Context at '"$PCT"'%! Consider saving." with title "Claude Code | WARNING" sound name "Glass"' &>/dev/null &
    elif (( PCT >= 70 )) && [[ ! -f "$FLAG_DIR/threshold-70" ]]; then
        printf '{"pct":%d,"t":"%s"}' "$PCT" "$NOW" > "$FLAG_DIR/threshold-70"
    fi
elif [[ "${STATUSLINE_FLAGS:-1}" != "0" ]] && (( PCT < 10 )); then
    FLAG_DIR="${STATUSLINE_FLAG_DIR:-$HOME/.claude/.context-flags}"
    [[ -d "$FLAG_DIR" ]] && rm -f "$FLAG_DIR"/threshold-* 2>/dev/null
fi

# === ANSI shortcuts ===
R='\033[0m' D='\033[2m' SEP=" ${D}|${R} "

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
L2=$(printf '\033[33m%s\033[0m%b\033[34m⏱ %s\033[0m %b(api %s)%b%b\033[32m+%s\033[0m/\033[31m-%s\033[0m' \
    "$COST_FMT" "$SEP" "$DURATION_FMT" "$D" "$API_DUR_FMT" "$R" "$SEP" "$LINES_ADDED" "$LINES_REMOVED")

[[ -n "$GIT_BRANCH" ]] && L2+=$(printf '%b\033[35m⎇ %s\033[0m' "$SEP" "$GIT_BRANCH")
[[ -n "$DIR_NAME" ]]   && L2+=$(printf '%b%b📂 %s%b' "$SEP" "$D" "$DIR_NAME" "$R")
[[ -n "$VIM_MODE" ]]   && { [[ "$VIM_MODE" == "NORMAL" ]] && L2+=$(printf '%b\033[34m[N]\033[0m' "$SEP") || L2+=$(printf '%b\033[32m[I]\033[0m' "$SEP"); }
[[ -n "$AGENT_NAME" ]] && L2+=$(printf '%b\033[36m🤖 %s\033[0m' "$SEP" "$AGENT_NAME")
[[ "$EXCEEDS_200K" == "true" ]] && L2+=$(printf ' \033[31m⚠ >200K\033[0m')

printf '%b\n' "$L2"
