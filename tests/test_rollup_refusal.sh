#!/usr/bin/env bash
# test_rollup_refusal.sh — a block the summary model cannot or will not write
#
# Usage: tests/test_rollup_refusal.sh
#
# Why: the tier-1 build walks forward and died on the first block it could
# not summarize, which threw away the whole --context output. On 2026-10-03
# Anthropic's content filter refused one ordinary window of Harris's log, so
# every wake for 12 days rebuilt that block, died, and woke with no life
# summary at all. These tests pin the new behavior: a refusal seals a
# placeholder and the build moves on, any other failure stops the build but
# still prints what exists, and one call seals a bounded number of blocks.
# A sealed placeholder is not permanent either: refusals drift in time
# (2026-10-15: re-sending the same bytes stopped the refusal on 2 of 3
# windows days after they refused, though both replies came back
# malformed), so a later build retries it, re-seals the
# placeholder if it refuses again, and keeps it untouched when the retry
# reply is malformed, without ever re-damming the build.
#
# The `llm` CLI is stubbed (canned rollup JSON, calls logged): no network.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

# --- stub llm: refuses REFUSE-ME, fails FLAKY while $FLAKY_ON exists --------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf 'CALL\n%s\n---\n' "$input" >> "$LLM_LOG"
if [[ "$input" == *REFUSE-ME* ]]; then
    echo "llm: error: refused: the provider content filter blocked this request (finish_reason content_filter)" >&2
    exit 1
fi
if [[ "$input" == *FLAKY* && -e "$FLAKY_ON" ]]; then
    echo "llm: error: empty response: stream ended without emitting anything" >&2
    exit 1
fi
if [[ "$input" == *REFUSE-ONCE* && -e "$REFUSE_ONCE_ON" ]]; then
    echo "llm: error: refused: the provider content filter blocked this request (finish_reason content_filter)" >&2
    exit 1
fi
if [[ "$input" == *GARBAGE* && -e "$GARBAGE_ON" ]]; then
    printf 'this is not json, just words\n'
    exit 0
fi
n=$(printf '%s' "$input" | wc -l | tr -d ' ')
printf '{"summary":"rollup of %s lines","themes":["testing"],"step_ids":["st000001"]}' "$n"
EOF
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export LLM_LOG="$WORK/llm.log" FLAKY_ON="$WORK/flaky_on"
export REFUSE_ONCE_ON="$WORK/refuse_once_on" GARBAGE_ON="$WORK/garbage_on"
unset TRAJ_DIR TRAJ_ID RECAP_MODEL SHELLM_FAST_MODEL SHELLM_MODEL ROLLUP_MAX_SEALS ROLLUP_REFUSED_RETRY_HOURS 2>/dev/null || true

TRAJ_ROOT="$WORK/trajectories"

mk_traj() { # mk_traj <run-name> <n-signal-steps> [<step-no> <marker>]
    local run="$TRAJ_ROOT/$1" i content
    mkdir -p "$run/rollups"
    printf '{"start_index":0,"updated":"t"}\n' > "$run/rollups/meta.json"
    printf '{"type":"trajectory","step_id":"%s-0000-4000-8000-000000000000","ts":"t0"}\n' \
        "${1%%-*}" > "$run/trajectory.jsonl"
    for (( i = 1; i <= $2; i++ )); do
        content="thinking about topic $i"
        [[ "$i" == "${3:-}" ]] && content="$content $4"
        printf '{"type":"thought","step_id":"st%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"%s"}\n' \
            "$i" $((i % 60)) "$content" >> "$run/trajectory.jsonl"
    done
}

blockfile() { # blockfile <run-name> <tier> <s> <e>
    printf '%s/%s/rollups/t%s/%012d-%012d.json' "$TRAJ_ROOT" "$1" "$2" "$3" "$4"
}
sealed() { ls "$TRAJ_ROOT/$1/rollups/t1" 2>/dev/null | wc -l | tr -d ' '; }
calls_with() { grep -c "$1" "$LLM_LOG"; }
ctx() { recap "$1" --traj_dir "$TRAJ_ROOT" --context --raw-tail 0 "${@:2}" 2>"$WORK/stderr"; }

# ---------------------------------------------------------------------------
# 1. Refusal: block [10,20) is refused. It is sealed as a placeholder after
#    one call, the blocks after it seal, and the staircase prints.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj aaaa1111-root 55 13 REFUSE-ME
out=$(ctx aaaa1111)
rc=$?
check "refusal: exits 0"                     test "$rc" -eq 0
check "refusal: all five t1 blocks sealed"   test "$(sealed aaaa1111-root)" = "5"
check "refusal: block marked refused"        test "$(jq -r .refused "$(blockfile aaaa1111-root 1 10 20)")" = "true"
check "refusal: placeholder summary"         grep -q 'Not summarized' "$(blockfile aaaa1111-root 1 10 20)"
check "refusal: one call, no retry"          test "$(calls_with REFUSE-ME)" = "1"
check_not "refusal: good block not marked"   grep -q refused "$(blockfile aaaa1111-root 1 20 30)"
check "refusal: staircase printed"           grep -q 'YOUR LIFE SO FAR' <<<"$out"
check "refusal: placeholder line shown"      grep -q 'Not summarized' <<<"$out"
check "refusal: later block shown"           grep -q 'steps 40–50' <<<"$out"
: > "$LLM_LOG"
ctx aaaa1111 >/dev/null
check "refusal: next call does not retry it" test "$(calls_with REFUSE-ME)" = "0"

# ---------------------------------------------------------------------------
# 2. Other failure: block [20,30) fails. The build stops there, the block
#    stays unsealed for the next call, and what exists still prints.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj bbbb2222-root 55 23 FLAKY
touch "$FLAKY_ON"
out=$(ctx bbbb2222)
rc=$?
check "failure: exits 0"                     test "$rc" -eq 0
check "failure: blocks before it sealed"     test -f "$(blockfile bbbb2222-root 1 10 20)"
check_not "failure: failed block unsealed"   test -f "$(blockfile bbbb2222-root 1 20 30)"
check_not "failure: build stopped there"     test -f "$(blockfile bbbb2222-root 1 30 40)"
check "failure: staircase still printed"     grep -q 'steps 10–20' <<<"$out"
check "failure: stop noted on stderr"        grep -q 'stopping the build' "$WORK/stderr"
rm -f "$FLAKY_ON"
ctx bbbb2222 >/dev/null
check "failure: next call seals the rest"    test "$(sealed bbbb2222-root)" = "5"
check_not "failure: not marked refused"      grep -q refused "$(blockfile bbbb2222-root 1 20 30)"

# ---------------------------------------------------------------------------
# 3. Cap: nine pending blocks, ROLLUP_MAX_SEALS=4. Each call seals four;
#    --backfill has no cap.
# ---------------------------------------------------------------------------
mk_traj cccc3333-root 95
out=$(ROLLUP_MAX_SEALS=4 ctx cccc3333)
rc=$?
check "cap: exits 0"                         test "$rc" -eq 0
check "cap: four sealed on the first call"   test "$(sealed cccc3333-root)" = "4"
check "cap: oldest blocks first"             test -f "$(blockfile cccc3333-root 1 30 40)"
check "cap: noted on stderr"                 grep -q 'the cap for one call' "$WORK/stderr"
check "cap: staircase printed"               grep -q 'YOUR LIFE SO FAR' <<<"$out"
ROLLUP_MAX_SEALS=4 ctx cccc3333 >/dev/null
check "cap: eight after the second call"     test "$(sealed cccc3333-root)" = "8"
mk_traj dddd4444-root 95
ROLLUP_MAX_SEALS=4 ctx dddd4444 --backfill >/dev/null
check "cap: --backfill seals everything"     test "$(sealed dddd4444-root)" = "9"
ROLLUP_MAX_SEALS=x ctx dddd4444 >/dev/null
check "cap: a bad value is refused"          grep -q 'ROLLUP_MAX_SEALS must be a number' "$WORK/stderr"

# ---------------------------------------------------------------------------
# 4. Retry: once ROLLUP_REFUSED_RETRY_HOURS has passed, the placeholder is
#    re-asked. A refusal is not decided by the window's text (2026-10-15:
#    re-sending identical bytes summarized 2 of 3 windows that had refused
#    for days), so a later build can recover the block, and every higher
#    tier that summarized the placeholder is rebuilt from it.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj eeee5555-root 155 13 REFUSE-ONCE
touch "$REFUSE_ONCE_ON"
ctx eeee5555 >/dev/null
check "retry: placeholder sealed"            test "$(jq -r .refused "$(blockfile eeee5555-root 1 10 20)")" = "true"
check "retry: t2 sealed over the placeholder" test -f "$(blockfile eeee5555-root 2 0 100)"
rm -f "$REFUSE_ONCE_ON"
ctx eeee5555 >/dev/null
check "retry: fresh placeholder not retried"  test "$(calls_with REFUSE-ONCE)" = "1"
touch -t 202001010000 "$(blockfile eeee5555-root 1 10 20)"
touch "$WORK/before_recovery"
out=$(ctx eeee5555)
rc=$?
check "retry: exits 0"                       test "$rc" -eq 0
check "retry: re-asked once"                 test "$(calls_with REFUSE-ONCE)" = "2"
check "retry: block recovered"               test -z "$(jq -r '.refused // empty' "$(blockfile eeee5555-root 1 10 20)")"
check "retry: real summary sealed"           grep -q 'rollup of' "$(blockfile eeee5555-root 1 10 20)"
check "retry: placeholder rewritten"        test -n "$(find "$(blockfile eeee5555-root 1 10 20)" -newer "$WORK/before_recovery")"
check "retry: t2 rebuilt over it"            test -n "$(find "$(blockfile eeee5555-root 2 0 100)" -newer "$WORK/before_recovery")"
check "retry: untouched block left alone"    test -z "$(find "$(blockfile eeee5555-root 1 20 30)" -newer "$WORK/before_recovery")"
check "retry: staircase printed"             grep -q 'YOUR LIFE SO FAR' <<<"$out"

# ---------------------------------------------------------------------------
# 5. Repeat refusal: the retry asks again, the model refuses again, and the
#    placeholder is re-sealed with a fresh mtime so the next retry waits
#    another floor instead of firing on every call.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj ffff6666-root 55 13 REFUSE-ME
ctx ffff6666 >/dev/null
check "re-refusal: placeholder sealed"        test "$(jq -r .refused "$(blockfile ffff6666-root 1 10 20)")" = "true"
touch -t 202001010000 "$(blockfile ffff6666-root 1 10 20)"
ctx ffff6666 >/dev/null
check "re-refusal: re-asked once"             test "$(calls_with REFUSE-ME)" = "2"
check "re-refusal: placeholder kept"          test "$(jq -r .refused "$(blockfile ffff6666-root 1 10 20)")" = "true"
check "re-refusal: text kept"                 grep -q 'Not summarized' "$(blockfile ffff6666-root 1 10 20)"
check "re-refusal: mtime restamped"           test -z "$(find "$(blockfile ffff6666-root 1 10 20)" -maxdepth 0 -mmin +60 2>/dev/null)"
ctx ffff6666 >/dev/null
check "re-refusal: next call waits"           test "$(calls_with REFUSE-ME)" = "2"
ROLLUP_REFUSED_RETRY_HOURS=0 ctx ffff6666 >/dev/null
check "re-refusal: zero floor retries now"    test "$(calls_with REFUSE-ME)" = "3"

# ---------------------------------------------------------------------------
# 6. Malformed retry: the re-ask returns non-JSON (the 2026-10-15 retest saw
#    two such replies). The placeholder stays, the build keeps going past
#    it, and the retry waits another floor.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj gggg7777-root 55 13 "REFUSE-ONCE GARBAGE"
touch "$REFUSE_ONCE_ON"
ctx gggg7777 >/dev/null
check "garbage retry: placeholder sealed"     test "$(jq -r .refused "$(blockfile gggg7777-root 1 10 20)")" = "true"
rm -f "$REFUSE_ONCE_ON"
touch "$GARBAGE_ON"
touch -t 202001010000 "$(blockfile gggg7777-root 1 10 20)"
out=$(ctx gggg7777)
rc=$?
check "garbage retry: exits 0"               test "$rc" -eq 0
check "garbage retry: two retry attempts"    test "$(calls_with GARBAGE)" = "3"
check "garbage retry: placeholder kept"      test "$(jq -r .refused "$(blockfile gggg7777-root 1 10 20)")" = "true"
check "garbage retry: build not stopped"     grep -q 'steps 40–50' <<<"$out"
check "garbage retry: retry kept it"         grep -q 'keeping the placeholder' "$WORK/stderr"
rm -f "$GARBAGE_ON"
: > "$LLM_LOG"
ctx gggg7777 >/dev/null
check "garbage retry: next call waits"        test "$(calls_with GARBAGE)" = "0"

# ---------------------------------------------------------------------------
# 7. Cap: a retry is a seal, so it counts against ROLLUP_MAX_SEALS and the
#    rest of the build waits when the retry uses the last slot.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj hhhh8888-root 95 13 REFUSE-ONCE
touch "$REFUSE_ONCE_ON"
ROLLUP_MAX_SEALS=3 ctx hhhh8888 >/dev/null
rm -f "$REFUSE_ONCE_ON"
check "cap: placeholder sealed"               test "$(jq -r .refused "$(blockfile hhhh8888-root 1 10 20)")" = "true"
touch -t 202001010000 "$(blockfile hhhh8888-root 1 10 20)"
: > "$LLM_LOG"
ROLLUP_MAX_SEALS=1 ctx hhhh8888 >/dev/null
check "cap: retry used the slot"              test "$(calls_with REFUSE-ONCE)" = "1"
check "cap: block recovered"                  test -z "$(jq -r '.refused // empty' "$(blockfile hhhh8888-root 1 10 20)")"
check_not "cap: nothing else sealed"          test -f "$(blockfile hhhh8888-root 1 30 40)"
check "cap: cap noted on stderr"              grep -q 'the cap for one call' "$WORK/stderr"

# ---------------------------------------------------------------------------
# 8. Validation: the floor is a number of hours, 0 meaning every call.
# ---------------------------------------------------------------------------
ROLLUP_REFUSED_RETRY_HOURS=x ctx hhhh8888 >/dev/null
check "floor: a bad value is refused"         grep -q 'ROLLUP_REFUSED_RETRY_HOURS must be a number' "$WORK/stderr"
ROLLUP_REFUSED_RETRY_HOURS=-1 ctx hhhh8888 >/dev/null
check "floor: a negative value is refused"    grep -q 'ROLLUP_REFUSED_RETRY_HOURS must be a number' "$WORK/stderr"

# ---------------------------------------------------------------------------
# 9. Crash mid-retry: a retry moves the placeholder aside before re-asking;
#    a crash between that move and the re-seal leaves only the aside, and
#    the next build restores it, never losing the window. A crash after a
#    successful re-seal leaves a live block plus the aside; the next build
#    keeps the block and discards the aside.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj jjjj9999-root 155 13 REFUSE-ONCE
touch "$REFUSE_ONCE_ON"
ctx jjjj9999 >/dev/null
check "crash: placeholder sealed"            test -f "$(blockfile jjjj9999-root 1 10 20)"
rm -f "$REFUSE_ONCE_ON"
mv "$(blockfile jjjj9999-root 1 10 20)" "$(blockfile jjjj9999-root 1 10 20).retry.tmp"
touch -t 202001010000 "$(blockfile jjjj9999-root 1 10 20).retry.tmp"
: > "$LLM_LOG"
ctx jjjj9999 >/dev/null
check "crash: aside restored and re-asked"   test "$(calls_with REFUSE-ONCE)" -ge 1
check "crash: window recovered"              grep -q 'rollup of' "$(blockfile jjjj9999-root 1 10 20)"
check "crash: aside consumed"                test ! -e "$(blockfile jjjj9999-root 1 10 20).retry.tmp"
check "crash: tiers above rebuilt"           grep -q 'pruned t2' "$WORK/stderr"
cp "$(blockfile jjjj9999-root 1 10 20)" "$(blockfile jjjj9999-root 1 10 20).retry.tmp"
touch -t 202001010000 "$(blockfile jjjj9999-root 1 10 20).retry.tmp"
before=$(jq -r .summary "$(blockfile jjjj9999-root 1 10 20)")
: > "$LLM_LOG"
ctx jjjj9999 >/dev/null
check "crash: stale aside discarded"         test ! -e "$(blockfile jjjj9999-root 1 10 20).retry.tmp"
check "crash: live block kept"               test "$(jq -r .summary "$(blockfile jjjj9999-root 1 10 20)")" = "$before"
check "crash: live block not re-asked"       test "$(calls_with REFUSE-ONCE)" = "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
