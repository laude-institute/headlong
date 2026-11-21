#!/usr/bin/env bash
# test_rollup_message_render_direction.sh — the rollup input renders message
# rows, and the old render wrote "[id] message(chat) FROM→TO: content": the
# model read the persona's own name into the wrong side of the arrow and
# sealed summaries narrated outbound messages as messages received (fold
# inversion; measured 2026-11-05 on a copy of the live summaries, 60 of 132
# resealed blocks kept the flipped reading under the arrow gloss, and the
# measured cure was the verb-led nameless row: 12 of 12 flip-family blocks
# clean, 5 of 5 controls clean).
#
# These tests pin the shipped render: the persona's outbound rows read
# "I sent to RECIPIENT:", rows addressed to the persona read
# "SENDER sent to me:", rows between third parties read
# "SENDER sent to RECIPIENT:", the persona's name never appears in a row,
# the rollup prompt documents the verb-led forms, sealed blocks stamp
# prompt_version 7, a version-1 cached render (arrow rows) is rebuilt rather
# than mixed, and a caller that names no identity gets the third-party form
# for every row — direction stays true, no first-person claim is invented.
#
# The `llm` CLI is stubbed (system prompt and input logged, canned rollup
# JSON): no network.

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

# --- stub llm: system prompt and input logged, canned JSON back -----------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf 'SYSTEM\n%s\nUSER\n%s\n---\n' "$*" "$input" >> "$LLM_LOG"
printf '{"summary":"rollup ok","themes":["testing"],"step_ids":["st000001"]}'
EOF
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export LLM_LOG="$WORK/llm.log"
unset TRAJ_DIR TRAJ_ID RECAP_MODEL SHELLM_FAST_MODEL SHELLM_MODEL \
      IDENTITY_NAME IDENTITY_DIR RECAP_SELF 2>/dev/null || true

TRAJ_ROOT="$WORK/trajectories"

mk_rows() { # mk_rows <run-root-name> — 15 signal rows, 3 of them message rows
    local run="$TRAJ_ROOT/$1" i
    mkdir -p "$run"
    printf '{"type":"trajectory","step_id":"%s","ts":"2026-07-17T10:00:00"}\n' "$1" > "$run/trajectory.jsonl"
    for (( i = 1; i <= 4; i++ )); do
        printf '{"type":"thought","step_id":"th%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"thinking about topic %d"}\n' \
            "$i" "$i" "$i" >> "$run/trajectory.jsonl"
    done
    printf '{"type":"message","step_id":"msout0001","ts":"2026-07-17T10:05:00","source":"chat","from":"tester","to":"slack-UAAA","content":"outbound hello"}\n' >> "$run/trajectory.jsonl"
    printf '{"type":"message","step_id":"msin0001","ts":"2026-07-17T10:06:00","source":"chat","from":"slack-UAAA","to":"tester","content":"inbound hello"}\n' >> "$run/trajectory.jsonl"
    printf '{"type":"message","step_id":"msrel0001","ts":"2026-07-17T10:07:00","source":"chat","from":"slack-BBB","to":"slack-CCC","content":"relay note"}\n' >> "$run/trajectory.jsonl"
    for (( i = 5; i <= 12; i++ )); do
        printf '{"type":"thought","step_id":"th%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"thinking about topic %d"}\n' \
            "$i" "$i" "$i" >> "$run/trajectory.jsonl"
    done
}

export RECAP_SELF=tester

# --- 1. Sealing pass: prompt documented, block stamped --------------------
mk_rows dire0001-root
: > "$LLM_LOG"
recap dire0001 --traj_dir "$TRAJ_ROOT" --backfill >/dev/null 2>&1
rc=$?
check "seal: exits 0" test "$rc" -eq 0
blk="$TRAJ_ROOT/dire0001-root/rollups/t1/000000000000-000000000010.json"
check "seal: t1 block exists" test -f "$blk"
check "seal: prompt_version 7 stamped" jq -e '.prompt_version == 7' "$blk"
check "prompt: verb-led outbound form documented" grep -q 'I sent to RECIPIENT: content' "$LLM_LOG"
check "prompt: verb-led inbound form documented"  grep -q 'SENDER sent to me: content' "$LLM_LOG"
check "prompt: own-name rule documented"          grep -q 'your own name never appears in a message line' "$LLM_LOG"
check_not "prompt: arrow gloss retired"           grep -q 'the name before the arrow' "$LLM_LOG"

# --- 2. Render cache rows: verb-led, no arrow, no persona name -------------
TSV="$TRAJ_ROOT/dire0001-root/rollups/rendered.tsv"
RMETA="$TRAJ_ROOT/dire0001-root/rollups/rendered.meta.json"
recap dire0001 --traj_dir "$TRAJ_ROOT" --context --raw-tail 3 >/dev/null 2>&1
rc=$?
check "render: exits 0" test "$rc" -eq 0
check "render: cache exists"        test -f "$TSV"
check "render: 15 signal rows"      test "$(wc -l < "$TSV" | tr -d ' ')" = "15"
check "render: outbound verb-led"   grep -q 'message(chat) I sent to slack-UAAA:' "$TSV"
check "render: inbound verb-led"    grep -q 'message(chat) slack-UAAA sent to me:' "$TSV"
check "render: third-party names both" grep -q 'message(chat) slack-BBB sent to slack-CCC:' "$TSV"
check_not "render: no arrow in any row"  grep -q '→' "$TSV"
check_not "render: persona name in no row" grep -q 'message(chat) tester' "$TSV"

# --- 3. A version-1 cache (arrow rows) is rebuilt, not mixed ----------------
sed 's/ I sent to slack-UAAA:/ tester→slack-UAAA:/' "$TSV" > "$TSV.plant" && mv "$TSV.plant" "$TSV"
jq '.version = 1' "$RMETA" > "$RMETA.plant" && mv "$RMETA.plant" "$RMETA"
recap dire0001 --traj_dir "$TRAJ_ROOT" --context --raw-tail 3 >/dev/null 2>&1
rc=$?
check "migrate: exits 0" test "$rc" -eq 0
check "migrate: cache rebuilt verb-led" grep -q ' I sent to slack-UAAA:' "$TSV"
check_not "migrate: planted arrow row gone" grep -q 'tester→slack-UAAA' "$TSV"
check "migrate: meta stamped version 2" jq -e '.version == 2' "$RMETA"

# --- 4. No identity named: third-party form everywhere, no invented me ------
unset RECAP_SELF
mk_rows dire0002-root
TSV2="$TRAJ_ROOT/dire0002-root/rollups/rendered.tsv"
recap dire0002 --traj_dir "$TRAJ_ROOT" --context --raw-tail 3 >/dev/null 2>&1
rc=$?
check "fallback: exits 0" test "$rc" -eq 0
check "fallback: outbound names sender and recipient" grep -q 'message(chat) tester sent to slack-UAAA:' "$TSV2"
check_not "fallback: no first-person claim" grep -q ' I sent to \| sent to me' "$TSV2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
