#!/usr/bin/env bash
# test_rollup_supersession_prompt.sh — the rollup prompt names its correction targets
#
# Usage: tests/test_rollup_supersession_prompt.sh
#
# Prompt v5 lets a parent summary cite an earlier child by its exact
# "[id,...]" prefix, but only when the earlier claim and correcting evidence
# are both supplied in the same input. It cannot link separately sealed
# siblings absent from that input. These tests inspect actual tier-2 calls,
# including two disjoint ranges, without claiming to test model compliance.
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
bad()  { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label" "$2"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label" "$2"; else ok "$label"; fi; }

# --- stub llm: log system prompt AND user text, canned JSON back -----------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
printf 'SYSTEM\n%s\nUSER\n%s\n---\n' "$*" "$input" >> "$LLM_LOG"
case "$input" in
    *'[old00001,old00002]'*) printf '%s\n' "$input" > "$LLM_LOG.old-input" ;;
    *'[new00001,new00002]'*) printf '%s\n' "$input" > "$LLM_LOG.new-input" ;;
esac
printf '{"summary":"rollup ok","themes":["testing"],"step_ids":["st000001"]}'
STUB
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export LLM_LOG="$WORK/llm.log"
unset TRAJ_DIR TRAJ_ID RECAP_MODEL SHELLM_FAST_MODEL SHELLM_MODEL 2>/dev/null || true

TRAJ_ROOT="$WORK/trajectories"
mkdir -p "$TRAJ_ROOT/supe0001"
GJ="$TRAJ_ROOT/supe0001/trajectory.jsonl"
printf '{"type":"trajectory","step_id":"supe0001-0000-4000-8000-000000000000","ts":"t0"}\n' > "$GJ"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf '{"type":"thought","step_id":"st%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"thinking about topic %d"}\n' \
        "$i" $((i % 60)) "$i" >> "$GJ"
done

: > "$LLM_LOG"
recap supe0001 --traj_dir "$TRAJ_ROOT" --backfill >/dev/null 2>&1

# 1. The supersession instruction reaches the rollup model.
check "prompt: supersession citation instruction sent" \
    grep -q 'corrects or supersedes a claim' "$LLM_LOG"

# 2. The instruction names the child prefix format the model must quote.
check "prompt: child [id,...] prefix explained" \
    grep -q 'quoting its "\[id,\.\.\.\]" prefix' "$LLM_LOG"

# Both sides of a correction must be visible in the same model input.
check "prompt: correction requires shared input" \
    grep -q 'correcting evidence is also present in this input' "$LLM_LOG"
check "prompt: unseen prefixes forbidden" \
    grep -q 'do not invent or infer a prefix for an unseen window' "$LLM_LOG"
# Message rows carry an arrow the model could read backwards; the prompt
# says which side is the sender. Sealed summaries flipped outbound to
# inbound before this sentence existed.
check "prompt: message-row direction documented" \
    grep -q 'the name before the arrow is the sender' "$LLM_LOG"


# 4. Sealed blocks are stamped with prompt_version 6.
blk="$TRAJ_ROOT/supe0001/rollups/t1/000000000000-000000000010.json"
check "sealed block exists" test -f "$blk"
check "sealed block stamped prompt_version 6" \
    jq -e '.prompt_version == 6' "$blk"

# 5. The stub was actually called (log has at least one CALL/SYSTEM record).
check "rollup model invoked" grep -q '^SYSTEM$' "$LLM_LOG"

# 6. Supply 20 sealed children across two disjoint tier-2 ranges. The
# correction in [100,200) cannot see the claim in [0,100). Preseeding t1
# makes the summaries deterministic; recap itself constructs the t2 inputs.
mkdir -p "$TRAJ_ROOT/scope001/rollups/t1"
GJ="$TRAJ_ROOT/scope001/trajectory.jsonl"
printf '{"type":"trajectory","step_id":"scope001-root","ts":"t0"}\n' > "$GJ"
for ((i=1; i<=200; i++)); do
    printf '{"type":"thought","step_id":"sc%06d","ts":"t1","content":"fixture step %d"}\n' "$i" "$i" >> "$GJ"
done
for ((i=0; i<20; i++)); do
    summary="I recorded unrelated work."
    ids='["other001","other002"]'
    case "$i" in
        0) summary="I attributed the issue to channel noise."
           ids='["old00001","old00002"]' ;;
        10) summary="I corrected the channel noise diagnosis: the cause was a resend loop."
            ids='["new00001","new00002"]' ;;
    esac
    file=$(printf '%s/scope001/rollups/t1/%012d-%012d.json' "$TRAJ_ROOT" "$((i*10))" "$((i*10+10))")
    jq -nc --arg summary "$summary" --argjson ids "$ids" \
        --argjson start "$((i*10))" --argjson end "$((i*10+10))" \
        '{tier:1,start:$start,end:$end,n:10,summary:$summary,step_ids:$ids,prompt_version:5}' > "$file"
done
check "scope: tier-2 generation succeeds" \
    recap scope001 --traj_dir "$TRAJ_ROOT" --backfill
check "input: first parent has exact child prefix and claim" \
    grep -qxF '[old00001,old00002] I attributed the issue to channel noise.' "$LLM_LOG.old-input"
check "input: second parent has exact correction child prefix" \
    grep -qxF '[new00001,new00002] I corrected the channel noise diagnosis: the cause was a resend loop.' "$LLM_LOG.new-input"
check "input: first parent receives ten children" \
    test "$(wc -l < "$LLM_LOG.old-input" | tr -d ' ')" = 10
check "input: second parent receives ten children" \
    test "$(wc -l < "$LLM_LOG.new-input" | tr -d ' ')" = 10
check_not "scope: correction absent from earlier parent" \
    grep -qF 'resend loop' "$LLM_LOG.old-input"
check_not "scope: earlier claim IDs absent from correcting parent" \
    grep -qF 'old00001' "$LLM_LOG.new-input"
check_not "scope: earlier claim text absent from correcting parent" \
    grep -qF 'I attributed the issue to channel noise.' "$LLM_LOG.new-input"
check "scope: second tier-2 block sealed" \
    test -f "$TRAJ_ROOT/scope001/rollups/t2/000000000100-000000000200.json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
