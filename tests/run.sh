#!/bin/bash
# Regression tests for statusline.sh. No network: curl and credential stores are stubbed.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/statusline.sh"
FIXTURES="$ROOT/tests/fixtures"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/statusline-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILED=0
PASSED=0
NOW=$(date +%s)
FUTURE_5H=$((NOW + 3600))
FUTURE_7D=$((NOW + 86400 * 2))
PAST=$((NOW - 60))
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S; }

# Fresh HOME and stubs per test; records every stubbed curl call in $STUB/curl.calls.
new_env() {
    TEST_HOME="$WORK/home.$RANDOM$RANDOM"
    STUB="$TEST_HOME/stub"
    mkdir -p "$TEST_HOME/.claude" "$STUB"
    for tool in curl security secret-tool; do
        cp "$FIXTURES/stub-$( [[ $tool == curl ]] && echo curl || echo credentials )" "$STUB/$tool"
        chmod +x "$STUB/$tool"
    done
    printf '{"claudeAiOauth":{"accessToken":"test-token","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}' > "$TEST_HOME/.claude/.credentials.json"
}

# Plain render with ANSI stripped. Network refreshes are off unless the test enables them.
render() {
    local stdin_json=$1
    printf '%s' "$stdin_json" \
        | env HOME="$TEST_HOME" PATH="$STUB:$PATH" STUB_DIR="$STUB" STATUSLINE_FLAGS=0 STATUSLINE_WINDOW_COUNTER=0 \
            bash "$SCRIPT" \
        | sed $'s/\033\\[[0-9;]*m//g'
}
block_refresh() { printf '%d' $((NOW + 3600)) > "$TEST_HOME/.claude/.usage-next-attempt"; }
cache() { printf '%s' "$1" > "$TEST_HOME/.claude/.usage-cache.json"; }

check() {
    local name=$1 result=$2
    if [[ "$result" == "ok" ]]; then
        PASSED=$((PASSED + 1)); printf 'ok   %s\n' "$name"
    else
        FAILED=$((FAILED + 1)); printf 'FAIL %s: %s\n' "$name" "$result"
    fi
}
has()  { [[ "$1" == *"$2"* ]] && echo ok || printf 'missing "%s" in: %s' "$2" "$1"; }
lacks() { [[ "$1" != *"$2"* ]] && echo ok || printf 'unexpected "%s" in: %s' "$2" "$1"; }

BASE='"model":{"display_name":"M"},"cwd":"/nonexistent","context_window":{"used_percentage":1}'
meters() { # session row optional via $1 = "with5h"
    local session=''
    [[ "${1:-}" == with5h ]] && session="{\"kind\":\"session\",\"group\":\"session\",\"percent\":40,\"resets_at\":\"$(iso "$FUTURE_5H").504439+00:00\"},"
    printf '{"five_hour":null,"seven_day":null,"limits":[%s{"kind":"weekly_all","group":"weekly","percent":41,"resets_at":"%s.504456+00:00"},{"kind":"weekly_scoped","group":"weekly","percent":30,"resets_at":"%s+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}' \
        "$session" "$(iso "$FUTURE_7D")" "$(iso "$FUTURE_7D")"
}

# --- Claude: plan without a 5-hour limit, Fable as a separate gauge
new_env; block_refresh; cache "$(meters)"
out=$(render "{$BASE}")
check "no session meter: no 5h gauge" "$(lacks "$out" '5h [')"
check "weekly gauge from limits[]" "$(has "$out" '7d [█████░░░░░] 59%')"
check "Fable gauge parses reset without fraction" "$(has "$out" 'Fable [███████░░░] 70% ↻')"

# --- Claude: session meter present
new_env; block_refresh; cache "$(meters with5h)"
out=$(render "{$BASE}")
check "session meter renders 5h" "$(has "$out" '5h [██████░░░░] 60% ↻')"

# --- Claude: stdin wins, and an absent stdin window hides the cached one
new_env; block_refresh; cache "$(meters with5h)"
out=$(render "{$BASE,\"rate_limits\":{\"seven_day\":{\"used_percentage\":10.5,\"resets_at\":$FUTURE_7D}}}")
check "stdin seven_day overrides cache" "$(has "$out" '7d [█████████░] 90%')"
check "absent stdin five_hour hides cached 5h" "$(lacks "$out" '5h [')"
check "Fable still comes from cache" "$(has "$out" 'Fable [')"

new_env; block_refresh
out=$(render "{$BASE,\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$FUTURE_5H},\"seven_day\":{\"used_percentage\":41,\"resets_at\":$FUTURE_7D}}}")
check "stdin-only limits render" "$(has "$out" '5h [███████░░░] 77%')"

new_env; block_refresh
out=$(render "{$BASE,\"rate_limits\":{\"spend_limit\":{\"used_percentage\":62.8,\"resets_at\":$FUTURE_7D}}}")
check "gateway spend limit renders" "$(has "$out" 'spend [███░░░░░░░] 38%')"

# --- Claude: legacy cache shape, expired windows, stale marker, hostile label
new_env; block_refresh
cache "{\"five_hour\":{\"utilization\":10,\"resets_at\":\"$(iso "$FUTURE_5H").1+00:00\"},\"seven_day\":{\"utilization\":20,\"resets_at\":\"$(iso "$FUTURE_7D").1+00:00\"},\"seven_day_opus\":{\"utilization\":50,\"resets_at\":\"$(iso "$FUTURE_7D")+00:00\"}}"
out=$(render "{$BASE}")
check "legacy cache shape: 5h" "$(has "$out" '5h [█████████░] 90%')"
check "legacy cache shape: Opus" "$(has "$out" 'Opus [█████░░░░░] 50%')"

new_env; block_refresh
cache "{\"limits\":[{\"kind\":\"session\",\"percent\":4,\"resets_at\":\"$(iso "$PAST").5+00:00\"},{\"kind\":\"weekly_all\",\"percent\":41,\"resets_at\":\"$(iso "$FUTURE_7D").5+00:00\"}]}"
out=$(render "{$BASE}")
check "expired window is dropped" "$(lacks "$out" '5h [')"

new_env; block_refresh; cache "$(meters)"
touch -t 202001010000 "$TEST_HOME/.claude/.usage-cache.json"
out=$(render "{$BASE}")
check "old cache is marked stale" "$(has "$out" '~59%')"

new_env; block_refresh
cache "{\"limits\":[{\"kind\":\"weekly_scoped\",\"percent\":1,\"resets_at\":null,\"scope\":{\"model\":{\"display_name\":\"Evil\\u001b[31m\"}}}]}"
out=$(printf '%s' "{$BASE}" | env HOME="$TEST_HOME" PATH="$STUB:$PATH" STATUSLINE_FLAGS=0 STATUSLINE_WINDOW_COUNTER=0 bash "$SCRIPT" | tail -1)
check "control characters are stripped from labels" "$(lacks "$out" $'Evil\033')"

new_env; block_refresh; printf 'not json' > "$TEST_HOME/.claude/.usage-cache.json"
out=$(render "{$BASE}")
check "corrupt cache does not break rendering" "$(has "$out" 'M |')"

# --- Claude: fetching
new_env
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "cold fetch caches response with null five_hour" "$(has "$out" 'Fable [')"
check "success schedules next attempt" "$([[ -s "$TEST_HOME/.claude/.usage-next-attempt" ]] && echo ok || echo 'no next-attempt file')"

new_env
printf '{"error":{}}' > "$STUB/curl.body"; printf '429' > "$STUB/curl.code"; printf '1800' > "$STUB/curl.retry"
cache_before="$(meters)"; cache "$cache_before"
render "{$BASE}" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$STUB/curl.calls" ]] && break; sleep 0.2; done
sleep 0.5
render "{$BASE}" >/dev/null; render "{$BASE}" >/dev/null; sleep 0.5
calls=$(wc -l < "$STUB/curl.calls" | tr -d ' ')
next=$(cat "$TEST_HOME/.claude/.usage-next-attempt")
check "429: renders don't re-request" "$([[ "$calls" == 1 ]] && echo ok || echo "calls=$calls")"
check "429: Retry-After is honoured" "$( (( next - NOW >= 1700 )) && echo ok || echo "delay=$((next - NOW))")"
check "429: cache is preserved" "$([[ "$(cat "$TEST_HOME/.claude/.usage-cache.json")" == "$cache_before" ]] && echo ok || echo changed)"
check "token isn't passed on the command line" "$(lacks "$(cat "$STUB/curl.calls")" 'test-token')"

# --- Other documented stdin fields
new_env; block_refresh
out=$(render "{$BASE,\"workspace\":{\"current_dir\":\"/x/proj\",\"repo\":{\"name\":\"r\"}},\"pr\":{\"number\":12,\"review_state\":\"approved\"}}")
check "documented .pr fields" "$(has "$out" '✅ PR#12')"
check "workspace.current_dir preferred" "$(has "$out" '📂 proj')"
out=$(render "{$BASE,\"workspace\":{\"repo\":{\"name\":\"r\"}},\"pr\":{\"number\":7,\"kind\":\"mr\"}}")
check "GitLab MR badge" "$(has "$out" '🟢 MR#7')"
out=$(render "{$BASE,\"workspace\":{\"repo\":{\"name\":\"r\"}}}")
check "no open PR nudge" "$(has "$out" '· no PR')"
out=$(render "{$BASE,\"github\":{\"repo\":\"o/r\",\"pr\":{\"number\":3,\"state\":\"merged\",\"draft\":false}}}")
check "older .github shape" "$(has "$out" '🟣 PR#3')"

# --- Subscription name
new_env; printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "profile unavailable: name from credential" "$(has "$out" 'Max 20x | 7d [')"
check "credential name stays expired so the profile is retried" "$( (( NOW - $(stat -c %Y "$TEST_HOME/.claude/.usage-plan" 2>/dev/null || stat -f %m "$TEST_HOME/.claude/.usage-plan") > 3600 )) && echo ok || echo fresh)"
check "plan file holds no token" "$(lacks "$(cat "$TEST_HOME/.claude/.usage-plan")" 'test-token')"

new_env; printf '{"error":{}}' > "$STUB/curl.body"; printf '429' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "plan is stored even when usage is rate limited" "$(has "$out" 'Max 20x')"

new_env; printf '{"claudeAiOauth":{"accessToken":"t","subscriptionType":"pro","rateLimitTier":"default_claude_ai"}}' > "$TEST_HOME/.claude/.credentials.json"
printf '%s' "$(meters with5h)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "Pro with 5h, weekly and Fable" "$(has "$out" 'Pro | 5h [')"
check "Pro shows weekly" "$(has "$out" '7d [')"
check "Pro shows Fable" "$(has "$out" 'Fable [')"

new_env; printf '{"claudeAiOauth":{"accessToken":"t","subscriptionType":"ultra"}}' > "$TEST_HOME/.claude/.credentials.json"
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "unknown tier still shows the type" "$(has "$out" 'Ultra | 7d [')"

new_env; printf '{"claudeAiOauth":{"accessToken":"t"}}' > "$TEST_HOME/.claude/.credentials.json"
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "no subscription type: no plan label" "$([[ ! -f "$TEST_HOME/.claude/.usage-plan" ]] && echo ok || echo 'plan file written')"

new_env; block_refresh; cache "$(meters)"; printf 'Max 20x\n' > "$TEST_HOME/.claude/.usage-plan"
out=$(printf '%s' "{$BASE}" | env HOME="$TEST_HOME" PATH="$STUB:$PATH" STATUSLINE_PLAN=0 STATUSLINE_FLAGS=0 STATUSLINE_WINDOW_COUNTER=0 bash "$SCRIPT")
check "STATUSLINE_PLAN=0 hides the plan" "$(lacks "$out" 'Max 20x')"

new_env; printf '{"organization":{"plan_display_name":"Ultra","rate_limit_tier":"default_claude_max_20x"}}' > "$STUB/profile.body"
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "profile name beats stale max_20x credential" "$(has "$out" 'Ultra | 7d [')"
check "profile name replaces credential name" "$(lacks "$out" 'Max 20x')"

new_env; printf 'Ultra\n' > "$TEST_HOME/.claude/.usage-plan"; printf '{"organization":{"plan_display_name":"Pro"}}' > "$STUB/profile.body"
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "fresh plan: profile isn't requested" "$([[ ! -f "$STUB/profile.calls" ]] && echo ok || echo requested)"

new_env; printf 'Ultra\n' > "$TEST_HOME/.claude/.usage-plan"; touch -t 202001010000 "$TEST_HOME/.claude/.usage-plan"; printf '{"organization":{"plan_display_name":"Pro"}}' > "$STUB/profile.body"
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "expired plan is refreshed" "$(has "$out" 'Pro | 7d [')"

new_env; printf 'Ultra\n' > "$TEST_HOME/.claude/.usage-plan"; touch -t 202001010000 "$TEST_HOME/.claude/.usage-plan"
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
out=$(render "{$BASE}")
check "profile failure keeps the known plan" "$(has "$out" 'Ultra | 7d [')"

new_env; printf '{"organization":{"plan_display_name":"Ul\\u001b[31mtra"}}' > "$STUB/profile.body"
printf '%s' "$(meters)" > "$STUB/curl.body"; printf '200' > "$STUB/curl.code"
render "{$BASE}" >/dev/null
check "plan name is sanitized" "$(lacks "$(cat "$TEST_HOME/.claude/.usage-plan")" $'\033')"

out=$(render "{$BASE,\"effort\":{\"level\":\"high\"}}")
check "effort level follows the model" "$(has "$out" 'M high |')"

# --- Secondary text color
new_env; block_refresh; cache "$(meters)"
raw() { printf '%s' "{$BASE}" | env HOME="$TEST_HOME" PATH="$STUB:$PATH" STATUSLINE_FLAGS=0 "$@" bash "$SCRIPT"; }
out=$(raw X=1)
check "faint attribute isn't used" "$(lacks "$out" $'\033[2m')"
check "default muted color" "$(has "$out" $'\033[38;5;250m')"
out=$(raw STATUSLINE_MUTED_COLOR=255)
check "custom muted color" "$(has "$out" $'\033[38;5;255m')"
out=$(raw 'STATUSLINE_MUTED_COLOR=999;1')
check "invalid muted color falls back" "$(has "$out" $'\033[38;5;250m')"

# --- Toggle
new_env
out=$(printf '%s' "{$BASE,\"rate_limits\":{\"seven_day\":{\"used_percentage\":1,\"resets_at\":$FUTURE_7D}}}" | env HOME="$TEST_HOME" PATH="$STUB:$PATH" STUB_DIR="$STUB" STATUSLINE_USAGE_LIMITS=0 STATUSLINE_FLAGS=0 STATUSLINE_WINDOW_COUNTER=0 bash "$SCRIPT")
check "STATUSLINE_USAGE_LIMITS=0 hides limits" "$(lacks "$out" '7d [')"
check "STATUSLINE_USAGE_LIMITS=0 makes no requests" "$([[ ! -f "$STUB/curl.calls" ]] && echo ok || echo called)"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
