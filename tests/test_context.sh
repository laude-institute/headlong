#!/usr/bin/env bash
# test_context.sh — golden + invariant tests for bin/context
#
# Usage:
#   tests/test_context.sh            Run all tests
#   tests/test_context.sh --regen    Regenerate golden outputs from bin/context
#
# Golden tests render fixture trajectories (tests/fixtures/) with a matrix of
# flags and diff the output against checked-in goldens (tests/golden/).
# Invariant tests assert structural properties of the output regardless of
# goldens: valid JSON, alternating roles, valid UTF-8.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
CONTEXT="${CONTEXT_BIN:-$REPO/bin/context}"
FIXTURES="$HERE/fixtures"
GOLDEN="$HERE/golden"

# context shells out to traj; make sure the repo's copy wins
PATH="$REPO/bin:$PATH"
unset TRAJ_DIR TRAJ_ID 2>/dev/null || true

REGEN=0
[[ "${1:-}" == "--regen" ]] && REGEN=1
WORK_BK=$(mktemp -d)
trap 'rm -rf "$WORK_BK"' EXIT

PROD='--assistant-types reasoning,final --user-types prompt,shell-output,feedback --exclude-types sub-run,shellm-run,run-summary'

# case_id | fixture | flags
cases() {
    cat <<'EOF'
prod_basic|basic|PRODFLAGS
default_basic|basic|
headtail_basic|basic|--head 3 --tail 10 PRODFLAGS
trunc_basic|basic|--prompt-limit 200 PRODFLAGS
budget_basic|basic|--max-bytes 4000 PRODFLAGS
elnone_basic|basic|--tail 5 --elision-style none PRODFLAGS
pin_basic|basic|--tail 3 --pin b-010 PRODFLAGS
prod_empty|empty|PRODFLAGS
prod_junk|junk|PRODFLAGS
default_junk|junk|
prod_multibyte|multibyte|PRODFLAGS
trunc_multibyte|multibyte|--prompt-limit 100 PRODFLAGS
prod_blobs|blobs|PRODFLAGS
trunc_blobs|blobs|--prompt-limit 30 PRODFLAGS
EOF
}

pass=0
fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

run_case() {
    # run_case <fixture> <flags...> ; prints stdout, returns rc
    local fixture="$1"; shift
    "$CONTEXT" --traj_dir "$FIXTURES" "$fixture" "$@"
}

# ---------------------------------------------------------------------------
# Golden tests
# ---------------------------------------------------------------------------

mkdir -p "$GOLDEN"

while IFS='|' read -r case_id fixture flags; do
    [[ -z "$case_id" ]] && continue
    flags="${flags//PRODFLAGS/$PROD}"
    # shellcheck disable=SC2086
    out=$(run_case "$fixture" $flags 2>/dev/null)
    rc=$?

    if [[ "$REGEN" -eq 1 ]]; then
        printf '%s' "$out" > "$GOLDEN/$case_id.out"
        printf 'regen %s (rc=%s)\n' "$case_id" "$rc"
        continue
    fi

    if [[ "$rc" -ne 0 ]]; then
        bad "golden/$case_id" "exit code $rc"
        continue
    fi
    if [[ ! -f "$GOLDEN/$case_id.out" ]]; then
        bad "golden/$case_id" "missing golden (run --regen)"
        continue
    fi
    if diff -q <(printf '%s' "$out") "$GOLDEN/$case_id.out" >/dev/null 2>&1; then
        ok "golden/$case_id"
    else
        bad "golden/$case_id" "output differs from golden"
        diff <(printf '%s' "$out") "$GOLDEN/$case_id.out" | head -6 | sed 's/^/    /'
    fi
done < <(cases)

[[ "$REGEN" -eq 1 ]] && { printf 'goldens regenerated in %s\n' "$GOLDEN"; exit 0; }

# ---------------------------------------------------------------------------
# Invariant tests (golden-independent)
# ---------------------------------------------------------------------------

# 1. Output is a JSON array of {role, content} with alternating roles.
# shellcheck disable=SC2086
if run_case basic $PROD | jq -e '
        type == "array"
        and (map(.role) | all(. == "user" or . == "assistant"))
        and ([range(1; length) as $i | .[$i].role != .[$i-1].role] | all)
        and (map(.content | type == "string") | all)
    ' >/dev/null 2>&1; then
    ok "invariant/alternating-roles"
else
    bad "invariant/alternating-roles"
fi

# 2. Output is valid UTF-8 even when truncation hits multibyte characters.
# shellcheck disable=SC2086
if run_case multibyte --prompt-limit 100 $PROD 2>/dev/null | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    ok "invariant/valid-utf8-truncation"
else
    bad "invariant/valid-utf8-truncation"
fi

# 2c. Run scope and whole prompts. Two runs share a trajectory with a chat
# message between them; the second run's prompt is far over the field limit.
# --full-types prompt renders it whole (the model must never get a stub for
# its own instructions), --run keeps only that run's steps with no marker
# for the earlier rows, and a pinned prompt survives a tail window smaller
# than the run.
RS="$WORK_BK/runs"
mkdir -p "$RS/rs"
python3 - "$RS/rs/trajectory.jsonl" <<'PYEOF'
import json, sys
big = "PROMPT-HEAD " + ("x" * 3000) + " MIDDLE-MARKER " + ("y" * 3000) + " PROMPT-TAIL"
rows = [
  {"type": "trajectory", "step_id": "r-000"},
  {"type": "shellm-run", "step_id": "run-a"},
  {"type": "prompt", "content": "first run prompt FIRST-MARKER", "run_id": "run-a", "step_id": "pa"},
  {"type": "reasoning", "cmd": "echo a", "run_id": "run-a", "step_id": "ra"},
  {"type": "shell-output", "stdout": "a out", "exit": 0, "run_id": "run-a", "step_id": "oa"},
  {"type": "final", "content": "done a", "run_id": "run-a", "step_id": "fa"},
  {"type": "message", "content": "CHAT-MARKER hello", "step_id": "m1"},
  {"type": "shellm-run", "step_id": "run-b"},
  {"type": "prompt", "content": big, "run_id": "run-b", "step_id": "pb"},
  {"type": "reasoning", "cmd": "echo b1", "run_id": "run-b", "step_id": "rb1"},
  {"type": "shell-output", "stdout": "b1 out", "exit": 0, "run_id": "run-b", "step_id": "ob1"},
  {"type": "reasoning", "cmd": "echo b2", "run_id": "run-b", "step_id": "rb2"},
  {"type": "shell-output", "stdout": "B-BIG " * 1000, "exit": 0, "run_id": "run-b", "step_id": "ob2"},
]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PYEOF
# shellcheck disable=SC2086
rs_cut=$("$CONTEXT" --traj_dir "$RS" rs $PROD 2>/dev/null)
if printf '%s' "$rs_cut" | grep -q 'MIDDLE-MARKER'; then
    bad "run-scope/prompt-cut-by-default" "expected the 6K prompt to be truncated without --full-types"
else
    ok "run-scope/prompt-cut-by-default (documents the default; shellm passes --full-types prompt)"
fi
# shellcheck disable=SC2086
rs_full=$("$CONTEXT" --traj_dir "$RS" rs $PROD --full-types prompt 2>/dev/null)
if printf '%s' "$rs_full" | grep -q 'MIDDLE-MARKER' && printf '%s' "$rs_full" | grep -q 'FIRST-MARKER' \
   && printf '%s' "$rs_full" | grep -q 'truncated: 6000 bytes'; then
    ok "run-scope/full-types-prompt-whole (prompt whole, shell output still cut)"
else
    bad "run-scope/full-types-prompt-whole"
fi
# shellcheck disable=SC2086
rs_run=$("$CONTEXT" --traj_dir "$RS" rs $PROD --full-types prompt --run run-b --pin pb --head 0 2>/dev/null)
if printf '%s' "$rs_run" | grep -q 'MIDDLE-MARKER' \
   && ! printf '%s' "$rs_run" | grep -q -e 'FIRST-MARKER' -e 'CHAT-MARKER' -e 'done a' -e 'steps elided' \
   && [[ "$(printf '%s' "$rs_run" | jq -r '.[0].role + " " + (.[0].content[0:11])')" == "user PROMPT-HEAD" ]] \
   && [[ "$(printf '%s' "$rs_run" | jq 'length')" == "5" ]]; then
    ok "run-scope/only-this-run (prompt first, no other run, no chat, no marker)"
else
    bad "run-scope/only-this-run" "$(printf '%s' "$rs_run" | jq -r '.[] | .role + " " + (.content[0:30])' | tr '\n' '|')"
fi
# shellcheck disable=SC2086
rs_pin=$("$CONTEXT" --traj_dir "$RS" rs $PROD --full-types prompt --run run-b --pin pb --head 0 --tail 1 2>/dev/null)
if printf '%s' "$rs_pin" | grep -q 'MIDDLE-MARKER' && printf '%s' "$rs_pin" | grep -q '\[earlier steps elided\]' \
   && printf '%s' "$rs_pin" | grep -q 'B-BIG' && ! printf '%s' "$rs_pin" | grep -q 'b1 out'; then
    ok "run-scope/pinned-prompt-survives-small-tail"
else
    bad "run-scope/pinned-prompt-survives-small-tail" "$(printf '%s' "$rs_pin" | jq -r '.[] | .role + " " + (.content[0:30])' | tr '\n' '|')"
fi

# 2d. Block eviction. With --tail-block the window's start moves only every
# B rows, so the rendered prefix is identical between moves (provider prompt
# caches stay warm) and the window holds N to N+B-1 rows.
TB="$WORK_BK/tailblock"
mkdir -p "$TB/tb"
mk_rows() {  # mk_rows <count>
    python3 - "$TB/tb/trajectory.jsonl" "$1" <<'PYEOF'
import json, sys
out, n = sys.argv[1], int(sys.argv[2])
with open(out, "w") as f:
    for i in range(n):
        f.write(json.dumps({"type": "reasoning", "cmd": "echo row-%03d" % i, "step_id": "tb-%03d" % i}) + "\n")
PYEOF
}
first_row() {  # first rendered command's row number, and the message count
    # shellcheck disable=SC2086
    "$CONTEXT" --traj_dir "$TB" tb $PROD --head 0 --tail 20 --tail-block 10 2>/dev/null \
        | jq -r '(map(select(.role=="assistant")) | map(.content) | join("\n")) as $c | [($c | capture("row-(?<n>[0-9]+)") | .n | tonumber), ($c | [scan("row-")] | length)] | @tsv'
}
mk_rows 93; r93=$(first_row)
mk_rows 95; r95=$(first_row)
mk_rows 100; r100=$(first_row)
if [[ "$r93" == $'70\t23' && "$r95" == $'70\t25' && "$r100" == $'80\t20' ]]; then
    ok "tail-block/window-start-moves-in-blocks (93->row 70/23 rows, 95->row 70/25, 100->row 80/20)"
else
    bad "tail-block/window-start-moves-in-blocks" "got 93:[$r93] 95:[$r95] 100:[$r100]"
fi
# shellcheck disable=SC2086
plain=$("$CONTEXT" --traj_dir "$TB" tb $PROD --head 0 --tail 20 2>/dev/null | jq -r '[.[] | select(.role=="assistant")] | .[0].content')
if [[ "$plain" == *row-080* ]]; then
    ok "tail-block/default-block-1-is-a-plain-tail"
else
    bad "tail-block/default-block-1-is-a-plain-tail" "$plain"
fi

# 2b. Bookkeeping stamped on steps (token counts, latency, run id) never
# reaches the model; the thought and the code block do.
BK="$WORK_BK"
mkdir -p "$BK/bk"
cat > "$BK/bk/trajectory.jsonl" <<'EOF'
{"type": "prompt", "content": "Do the thing.", "source_url": "https://example.slack.com/archives/C1/p1", "step_id": "k-000", "ts": "2026-09-03T00:00:00Z"}
{"type": "reasoning", "thought": "Checking the log first.", "cmd": "tail -n 3 log.txt", "run_id": "run-1", "llm_s": 12, "in_tok": 31864, "out_tok": 337, "think_tok": 50, "cache_tok": 12000, "estimated": true, "served_by": "Xiaomi", "truncated": true, "some_future_field": "leak", "step_id": "k-001", "ts": "2026-09-03T00:00:01Z"}
{"type": "shell-output", "stdout": "line a\nline b\n", "exit": 0, "exec_s": 1, "run_id": "run-1", "step_id": "k-002", "ts": "2026-09-03T00:00:02Z"}
EOF
# shellcheck disable=SC2086
bk_out=$("$CONTEXT" --traj_dir "$BK" bk $PROD 2>/dev/null)
if printf '%s' "$bk_out" | grep -q -e '\[in_tok\]' -e '\[out_tok\]' -e '\[think_tok\]' -e '\[cache_tok\]' -e '\[llm_s\]' -e '\[run_id\]' -e '\[estimated\]' -e '\[source_url\]' -e '\[served_by\]' -e '\[truncated\]' -e '\[some_future_field\]' -e 'Xiaomi'; then
    bad "invariant/bookkeeping-hidden" "$(printf '%s' "$bk_out" | grep -o '\[[a-z_]*\]' | sort -u | tr '\n' ' ')"
elif printf '%s' "$bk_out" | grep -q 'Checking the log first' && printf '%s' "$bk_out" | grep -q 'tail -n 3 log.txt' \
     && printf '%s' "$bk_out" | grep -q '\[exit\]'; then
    ok "invariant/bookkeeping-hidden"
else
    bad "invariant/bookkeeping-hidden" "thought, cmd, or exit missing"
fi
# The model's own reply reads thought first and ends at the closing fence.
bk_reply=$(printf '%s' "$bk_out" | jq -r '[.[] | select(.role == "assistant")][0].content')
if [[ "$bk_reply" == $'Checking the log first.\n\n```bash\ntail -n 3 log.txt\n```' ]]; then
    ok "invariant/reply-ends-at-fence"
else
    bad "invariant/reply-ends-at-fence" "$bk_reply"
fi

# 3. Empty trajectory renders an empty array.
if [[ "$(run_case empty $PROD 2>/dev/null)" == "[]" ]]; then
    ok "invariant/empty-trajectory"
else
    bad "invariant/empty-trajectory"
fi

# 4. --max-bytes budget is respected.
# shellcheck disable=SC2086
budget_out=$(run_case basic --max-bytes 2000 $PROD 2>/dev/null)
if [[ "$(printf '%s' "$budget_out" | LC_ALL=C wc -c | tr -d ' ')" -le 2000 ]]; then
    ok "invariant/max-bytes-budget"
else
    bad "invariant/max-bytes-budget"
fi

# 5. Excluded types never appear in output.
# shellcheck disable=SC2086
if run_case basic $PROD | grep -q 'sub-run bookkeeping'; then
    bad "invariant/exclude-types"
else
    ok "invariant/exclude-types"
fi

# 6. Blob refs are loaded from disk; missing blobs keep inline content.
# shellcheck disable=SC2086
blob_out=$(run_case blobs $PROD 2>/dev/null)
if printf '%s' "$blob_out" | grep -q 'blob line one' \
   && printf '%s' "$blob_out" | grep -q 'inline kept'; then
    ok "invariant/blob-loading"
else
    bad "invariant/blob-loading"
fi

# 7. Process frugality: rendering must not fork per trajectory line.
#    (The old implementation forked ~10x per line; the rewrite is O(1).)
_p0=$(bash -c 'echo $$')
# shellcheck disable=SC2086
run_case basic $PROD >/dev/null 2>&1
_p1=$(bash -c 'echo $$')
_delta=$((_p1 - _p0))
if [[ "$_delta" -lt 0 ]]; then
    printf 'skip invariant/fork-count (pid wraparound)\n'
elif [[ "$_delta" -lt 150 ]]; then
    ok "invariant/fork-count ($_delta processes)"
else
    bad "invariant/fork-count" "$_delta processes spawned (expected < 150)"
fi

# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
