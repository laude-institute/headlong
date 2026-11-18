#!/usr/bin/env bash
# tests/test_llm_spend_limit.sh — bin/llm records what OpenRouter says each
# call cost, and stops calling once LLM_SPEND_LIMIT_USD is reached.
#
# Usage: tests/test_llm_spend_limit.sh
#
# The ledger gains a cost field from OpenRouter's usage.cost, on streamed and
# whole replies. A stream cut after its first code block (what bin/shellm
# asks for) would never read that final event, so under a limit the output
# still ends at the fence but the rest is read in silence, for at most the
# drain time. At or over the limit llm sends nothing, exits 3 and marks the
# health file with kind "budget". The limit is OpenRouter-only and counts one
# ledger, over a total, daily or monthly window. curl is stubbed: it logs
# every URL it is asked for, so "no request was sent" is checked, not
# assumed. No network.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# --- curl stub ----------------------------------------------------------------
# Streamed calls (-N) get $STREAM_FILE, one event every $STUB_DELAY seconds
# when that is set; whole calls (-o FILE) get $BODY_FILE and HTTP 200.
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/home"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="" out="" stream=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -N) stream=1; shift ;;
        -w|-K|-H|-d|--connect-timeout|--max-time|--speed-limit|--speed-time) shift 2 ;;
        -*) shift ;;
        *)  url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
if [[ "$stream" -eq 1 && -n "${STUB_DELAY:-}" ]]; then
    while IFS= read -r line; do
        printf '%s\n' "$line" || exit 23
        [[ -n "$line" ]] && sleep "$STUB_DELAY"
    done < "$STREAM_FILE"
elif [[ "$stream" -eq 1 ]]; then
    cat "$STREAM_FILE"
else
    cat "$BODY_FILE" > "$out"
    printf '200'
fi
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export CURL_LOG="$WORK/curl.log"
export HEADLONG_HOME="$WORK/home"
export LLM_USAGE_LEDGER="$WORK/ledger.jsonl"
export LLM_RETRIES=0
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_API_KEY LLM_API_KEY \
      LLM_PROVIDER LLM_API_URL LLM_MODEL LLM_MAX_TOKENS SHELLM_MODEL SHELLM_API_URL \
      SHELLM_HOME LLM_STOP_AFTER_CODE_BLOCK LLM_SPEND_LIMIT_USD LLM_SPEND_WINDOW \
      LLM_USAGE_FILE LLM_RUN_ID SHELLM_RUN_STEP_ID STUB_DELAY IDENTITY_DIR IDENTITY_NAME \
      LLM_OR_ONLY LLM_OR_DATA_COLLECTION LLM_OR_ZDR _LLM_SPEND_DRAIN_TIME
export OPENROUTER_API_KEY="test-openrouter-key"
cd "$WORK/run" || exit 1
LLM="$REPO/bin/llm"

reset() { : > "$CURL_LOG"; rm -f "$LLM_USAGE_LEDGER" "$LLM_USAGE_LEDGER.spend.json" "$HEADLONG_HOME/run/llm_health.json"; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
seed() { printf '{"ts":"%s","provider":"openrouter","model":"vendor/m","out_tok":1,"cost":%s}\n' "$1" "$2" >> "$LLM_USAGE_LEDGER"; }
requests() { grep -c . "$CURL_LOG" 2>/dev/null || true; }
last_cost() { tail -n 1 "$LLM_USAGE_LEDGER" 2>/dev/null | jq -r '.cost // "none"'; }
health() { jq -r "$1" "$HEADLONG_HOME/run/llm_health.json" 2>/dev/null; }

cat > "$WORK/stream.sse" <<'EOF'
data: {"id":"gen-test-1","provider":"Fake","choices":[{"delta":{"content":"hello"}}]}

data: {"id":"gen-test-1","provider":"Fake","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0.0125}}

data: [DONE]
EOF
# A code block, then text the caller does not want; the usage event comes last.
{
    printf 'data: %s\n\n' "$(jq -nc '{id:"gen-test-2",choices:[{delta:{content:"```bash\n"}}]}')"
    printf 'data: %s\n\n' "$(jq -nc '{id:"gen-test-2",choices:[{delta:{content:"echo hi\n"}}]}')"
    printf 'data: %s\n\n' "$(jq -nc '{id:"gen-test-2",choices:[{delta:{content:"```\n"}}]}')"
    printf 'data: %s\n\n' "$(jq -nc '{id:"gen-test-2",choices:[{delta:{content:"and then more\n"}}]}')"
    printf 'data: %s\n\n' "$(jq -nc '{id:"gen-test-2",choices:[{delta:{},finish_reason:"stop"}],usage:{prompt_tokens:10,completion_tokens:9,cost:0.5}}')"
    printf 'data: [DONE]\n'
} > "$WORK/cut.sse"
cat > "$WORK/body.json" <<'EOF'
{"id":"gen-test-3","provider":"Fake","choices":[{"message":{"content":"whole"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1,"cost":0.002}}
EOF
export STREAM_FILE="$WORK/stream.sse" BODY_FILE="$WORK/body.json"

# --- 1. no limit: --spend reports, nothing is enforced -------------------------
reset
out=$("$LLM" --spend 2>"$WORK/err"); rc=$?
check "--spend without a limit: exit 0, spent 0, limit and remaining null" \
    '[[ $rc -eq 0 ]] && [[ "$(printf "%s" "$out" | jq -c "[.spent, .limit, .remaining, .window]")" == "[0,null,null,\"total\"]" ]]' "rc=$rc out=$out"
check "--spend names the ledger it counts" \
    '[[ "$(printf "%s" "$out" | jq -r .ledger)" == "$LLM_USAGE_LEDGER" ]]'

# --- 2. cost lands in the ledger, streamed and whole ----------------------------
reset
out=$("$LLM" -m vendor/model "hi" 2>"$WORK/err"); rc=$?
check "streamed: the reply comes through" '[[ $rc -eq 0 && "$out" == "hello" ]]' "rc=$rc out=$out $(cat "$WORK/err")"
check "streamed: usage.cost is recorded in the ledger" '[[ "$(last_cost)" == "0.0125" ]]' "cost=$(last_cost)"

reset
out=$("$LLM" --no-stream -m vendor/model "hi" 2>"$WORK/err"); rc=$?
check "whole reply: usage.cost is recorded in the ledger" '[[ $rc -eq 0 && "$out" == "whole" && "$(last_cost)" == "0.002" ]]' "rc=$rc out=$out cost=$(last_cost)"

# --- 3. at or over the limit: nothing is sent, exit 3, kind budget --------------
reset
seed "$now" 1.5
LLM_SPEND_LIMIT_USD=1 "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "over the limit: exit 3" '[[ $rc -eq 3 ]]' "rc=$rc"
check "over the limit: no request was sent" '[[ "$(requests)" -eq 0 ]]' "requests=$(requests)"
check "over the limit: stderr says what was spent of what" 'grep -q "spend limit reached: \$1.5 of \$1 in total" "$WORK/err"' "$(cat "$WORK/err")"
check "over the limit: health marker is ok:false, kind budget" '[[ "$(health "[.ok, .kind] | @tsv")" == "false	budget" ]]' "$(health .)"
check "over the limit: the ledger gains no line" '[[ "$(grep -c . "$LLM_USAGE_LEDGER")" -eq 1 ]]'

reset
seed "$now" 2
LLM_SPEND_LIMIT_USD=2 "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "exactly at the limit counts as reached" '[[ $rc -eq 3 && "$(requests)" -eq 0 ]]' "rc=$rc"

# --- 4. under the limit: the call goes through and is counted -------------------
reset
seed "$now" 1.5
out=$(LLM_SPEND_LIMIT_USD=5 "$LLM" -m vendor/model "hi" 2>"$WORK/err"); rc=$?
check "under the limit: the call goes through" '[[ $rc -eq 0 && "$out" == "hello" && "$(last_cost)" == "0.0125" ]]' "rc=$rc $(cat "$WORK/err")"
spend=$(LLM_SPEND_LIMIT_USD=5 "$LLM" --spend)
check "--spend adds the new call: remaining 5 - 1.5125" \
    'printf "%s" "$spend" | jq -e ".limit == 5 and (.spent - 1.5125 | fabs) < 1e-9 and (.remaining - 3.4875 | fabs) < 1e-9" >/dev/null' "$spend"

# --- 5. windows: day and month only count their own lines -----------------------
reset
seed "2000-01-01T00:00:00Z" 100
seed "$now" 0.5
LLM_SPEND_LIMIT_USD=1 LLM_SPEND_WINDOW=day "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "day window: an old line does not count" '[[ $rc -eq 0 ]]' "rc=$rc $(cat "$WORK/err")"
LLM_SPEND_LIMIT_USD=1 LLM_SPEND_WINDOW=month "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "month window: an old line does not count" '[[ $rc -eq 0 ]]' "rc=$rc $(cat "$WORK/err")"
LLM_SPEND_LIMIT_USD=1 "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "total window: every line counts" '[[ $rc -eq 3 ]]' "rc=$rc"
spend=$(LLM_SPEND_LIMIT_USD=1 LLM_SPEND_WINDOW=day "$LLM" --spend)
check "--spend reports the window start" \
    '[[ "$(printf "%s" "$spend" | jq -r .since)" == "$(date -u +%Y-%m-%d)T00:00:00Z" ]]' "$spend"
seed "$now" 5
LLM_SPEND_LIMIT_USD=1 LLM_SPEND_WINDOW=day "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"
check "the message names the window" 'grep -q "of \$1 today" "$WORK/err"' "$(cat "$WORK/err")"

# --- 6. a torn or foreign line does not break the sum ---------------------------
reset
seed "$now" 0.25
printf '{"ts":"%s","cost":\n' "$now" >> "$LLM_USAGE_LEDGER"
printf 'not json at all\n' >> "$LLM_USAGE_LEDGER"
seed "$now" 0.25
spend=$(LLM_SPEND_LIMIT_USD=1 "$LLM" --spend 2>"$WORK/err"); rc=$?
check "a torn line is skipped, the rest still counts" \
    '[[ $rc -eq 0 ]] && printf "%s" "$spend" | jq -e ".spent == 0.5" >/dev/null' "rc=$rc $spend"

# --- 7. OpenRouter only, and settings are checked -------------------------------
reset
ANTHROPIC_API_KEY=test-anthropic LLM_SPEND_LIMIT_USD=5 "$LLM" -m claude-sonnet-4-5 "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "another provider with a limit set is refused, nothing sent" \
    '[[ $rc -eq 1 && "$(requests)" -eq 0 ]] && grep -q "supported only with OpenRouter" "$WORK/err"' "rc=$rc $(cat "$WORK/err")"
LLM_SPEND_LIMIT_USD='25$' "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "a limit that is not an amount is refused" '[[ $rc -eq 1 ]] && grep -q "must be a dollar amount" "$WORK/err"' "rc=$rc $(cat "$WORK/err")"
LLM_SPEND_LIMIT_USD=5 LLM_SPEND_WINDOW=week "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "an unknown window is refused" '[[ $rc -eq 1 ]] && grep -q "total, day or month" "$WORK/err"' "rc=$rc $(cat "$WORK/err")"
LLM_USAGE_LEDGER=/dev/null LLM_SPEND_LIMIT_USD=5 "$LLM" -m vendor/model "hi" >/dev/null 2>"$WORK/err"; rc=$?
check "a limit with the ledger disabled is refused" '[[ $rc -eq 1 && "$(requests)" -eq 0 ]] && grep -q "/dev/null" "$WORK/err"' "rc=$rc $(cat "$WORK/err")"

# --- 8. a stream cut after its first code block -------------------------------
# shellcheck disable=SC2034  # read inside check's eval'd conditions
fence=$'```bash\necho hi\n```'
export STREAM_FILE="$WORK/cut.sse"
reset
out=$("$LLM" -m vendor/model --stop-after-code-block "hi" 2>"$WORK/err"); rc=$?
check "no limit: cut at the fence as before, usage estimated, no cost" \
    '[[ $rc -eq 0 && "$out" == "$fence" ]] && grep -q "stopped reading after the first code block" "$WORK/err" && [[ "$(tail -n 1 "$LLM_USAGE_LEDGER" | jq -c "[.cost, .estimated]")" == "[null,true]" ]]' \
    "rc=$rc out=$out $(tail -n 1 "$LLM_USAGE_LEDGER")"

reset
out=$(LLM_SPEND_LIMIT_USD=5 "$LLM" -m vendor/model --stop-after-code-block "hi" 2>"$WORK/err"); rc=$?
check "under a limit: the output still ends at the closing fence" '[[ $rc -eq 0 && "$out" == "$fence" ]]' "rc=$rc out=$out"
check "under a limit: the usage event is read, so cost and real counts are recorded" \
    '[[ "$(tail -n 1 "$LLM_USAGE_LEDGER" | jq -c "[.cost, .in_tok, .out_tok, .estimated]")" == "[0.5,10,9,null]" ]]' "$(tail -n 1 "$LLM_USAGE_LEDGER")"

# A model that keeps writing after its block and never sends usage: reading
# stops after the drain time, and the call is recorded uncounted, with a warning.
{
    head -n 6 "$WORK/cut.sse"
    i=0; while [[ $i -lt 40 ]]; do
        printf 'data: %s\n\n' "$(jq -nc --arg i "$i" '{id:"gen-test-4",choices:[{delta:{content:("more " + $i + "\n")}}]}')"
        i=$((i+1))
    done
} > "$WORK/runaway.sse"
export STREAM_FILE="$WORK/runaway.sse"
reset
t0=$SECONDS
out=$(STUB_DELAY=0.1 _LLM_SPEND_DRAIN_TIME=1 LLM_SPEND_LIMIT_USD=5 "$LLM" -m vendor/model --stop-after-code-block "hi" 2>"$WORK/err"); rc=$?
took=$((SECONDS - t0))
check "runaway under a limit: output ends at the fence, and reading stops at the drain time" \
    '[[ $rc -eq 0 && "$out" == "$fence" && $took -lt 4 ]] && grep -q "stopped reading 1s after the first code block" "$WORK/err"' "rc=$rc took=${took}s $(cat "$WORK/err")"
check "runaway under a limit: recorded estimated and uncounted, with a warning" \
    '[[ "$(tail -n 1 "$LLM_USAGE_LEDGER" | jq -c "[.cost, .estimated]")" == "[null,true]" ]] && grep -q "the spend limit does not count it" "$WORK/err"' "$(cat "$WORK/err")"
unset STUB_DELAY

# --- 9. the sum is incremental: each check reads only what was appended -------
spent() { LLM_SPEND_LIMIT_USD=100 "$LLM" --spend | jq -r .spent; }
reset
seed "$now" 1
seed "$now" 2
check "first check sums the ledger" '[[ "$(spent)" == 3 ]]'
check "and leaves a cache next to it" '[[ "$(jq -r .offset "$LLM_USAGE_LEDGER.spend.json")" -eq "$(wc -c < "$LLM_USAGE_LEDGER" | tr -d " ")" ]]'
# Rewrite an early line's cost in place, same length: a re-read would see it.
awk 'NR == 1 { sub(/"cost":1/, "\"cost\":9") } { print }' "$LLM_USAGE_LEDGER" > "$WORK/l.tmp" && mv "$WORK/l.tmp" "$LLM_USAGE_LEDGER"
seed "$now" 4
check "an appended line is added, earlier lines are not read again" '[[ "$(spent)" == 7 ]]' "spent=$(spent)"
printf '{"ts":"%s","provider":"openrouter","cost":0.5' "$now" >> "$LLM_USAGE_LEDGER"
check "a line still being written is not counted yet" '[[ "$(spent)" == 7 ]]' "spent=$(spent)"
printf '}\n' >> "$LLM_USAGE_LEDGER"
check "and is counted once it is whole" '[[ "$(spent)" == 7.5 ]]' "spent=$(spent)"
check "a different window sums on its own" \
    '[[ "$(LLM_SPEND_LIMIT_USD=100 LLM_SPEND_WINDOW=day "$LLM" --spend | jq -r .spent)" == 15.5 && "$(spent)" == 15.5 ]]' \
    "day=$(LLM_SPEND_LIMIT_USD=100 LLM_SPEND_WINDOW=day "$LLM" --spend | jq -r .spent) total=$(spent)"
{ seed "$now" 0.25; seed "$now" 0.25; seed "$now" 0.25; seed "$now" 0.25; seed "$now" 0.25; } >/dev/null
mv "$LLM_USAGE_LEDGER" "$WORK/old.jsonl"
for i in 1 2 3 4 5 6 7 8; do seed "$now" 1; done
check "a replaced ledger, even a longer one, is summed from the start" '[[ "$(spent)" == 8 ]]' "spent=$(spent)"
rm -f "$LLM_USAGE_LEDGER"
check "a removed ledger counts nothing, and its cache goes with it" \
    '[[ "$(spent)" == 0 ]] && [[ ! -e "$LLM_USAGE_LEDGER.spend.json" ]]'

echo
echo "passed: $pass"
echo "failed: $fail"
[[ "$fail" -eq 0 ]]
