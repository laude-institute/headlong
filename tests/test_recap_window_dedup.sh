#!/usr/bin/env bash
# tests/test_recap_window_dedup.sh — every consumer that renders the fold's
# rows for a model (episode windows, tier-1 blocks, the context raw tail)
# reads a turn minted several times inside one run once, and rendered.tsv
# keeps every copy.
#
# Usage: tests/test_recap_window_dedup.sh
#
# Why: the 2026-11-14 stutter minted one thought three times inside one run,
# and bin/recap builds rendered.tsv through its own _render_steps, a path
# PR 252 never touched, so the fold's input kept the triplet. The widening
# placement spec puts the collapse at the window cut, where a summarizer
# reads rendered rows: the TSV keeps every row (positions, resume keys and
# the citable burst rows untouched; a new run-id and key column bumps
# RENDER_VERSION so the cache rebuilds once), adjacent rows of one run
# sharing the key collapse into the line the model reads, the survivor
# marked with its copy count, and the summarizer prompts say what the mark
# means. The `llm` CLI is stubbed (calls logged): no network.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

# --- stub llm: log the system prompt and the input, canned JSON back -------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
printf 'CALL\nSYS:%s\n%s\n---\n' "$*" "$input" >> "$LLM_LOG"
first_step=$(printf '%s' "$input" | grep -o '\[[0-9a-z?]\{1,8\}\]' | head -1 | tr -d '[]')
if printf '%s' "$input" | grep -q '^EPISODE '; then
    printf '{"arc":"the agent explored and built things","themes":[{"name":"exploration","description":"poking around","episodes":[1],"key_steps":[{"step":"%s","note":"first poke"}]}]}' "$first_step"
elif [[ "$*" == *"You summarize one window"* ]]; then
    n=$(printf '%s' "$input" | wc -l | tr -d ' ')
    printf '{"title":"window of %s steps","summary":"did %s things","themes":["doing-things"],"notable_steps":[{"step":"%s","note":"notable"}]}' "$n" "$n" "$first_step"
else
    printf '{"summary":"rollup ok","themes":["testing"],"step_ids":["%s"]}' "$first_step"
fi
STUB
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"

unset TRAJ_DIR TRAJ_ID RECAP_MODEL SHELLM_FAST_MODEL SHELLM_MODEL 2>/dev/null || true

TRAJ_ROOT="$WORK/trajectories"

mkest() { # mkest <dir> [extra filler rows] : a three-copy burst inside run-aa
    local RUN="$TRAJ_ROOT/$1" JSONL="$TRAJ_ROOT/$1/trajectory.jsonl" made=0
    mkdir -p "$RUN"
    printf '{"type":"trajectory","step_id":"%s-0000-4000-8000-000000000000","ts":"t0"}\n' "$1" >> "$JSONL"
    stepo() { # <type> <id> <content> [extra]
        made=$((made+1))
        printf '{"type":"%s","step_id":"%s","ts":"2026-07-17T10:%02d:00","source":"monolith","content":"%s"%s}\n' \
            "$1" "$2" $((made % 60)) "$3" "${4:-}" >> "$JSONL"
    }
    stepo thought pre1 "a quiet opener"             ',"run_id":"run-aa"'
    stepo thought bu1 "one turn minted three times" ',"run_id":"run-aa"'
    stepo thought bu2 "one turn minted three times" ',"run_id":"run-aa"'
    stepo thought bu3 "one turn minted three times" ',"run_id":"run-aa"'
    stepo thought mid1 "a neighbor between bursts"  ',"run_id":"run-aa"'
    stepo thought rep1 "one turn minted three times" ',"run_id":"run-bb"'
    stepo thought nr1 "no run id at all"
    stepo thought nr2 "no run id at all"
    stepo thought pst1 "a quiet closer"             ',"run_id":"run-aa"'
    local i
    for i in $(seq 1 "${2:-0}"); do
        stepo thought "fl$(printf '%04d' "$i")" "filler turn number $i" ',"run_id":"run-aa"'
    done
}

# ---------------------------------------------------------------------------
# Part A — the episode fold
# ---------------------------------------------------------------------------
mkest deadbeef-root
export LLM_LOG="$WORK/llm-a.log"
: > "$LLM_LOG"
recap deadbeef --traj_dir "$TRAJ_ROOT" --window 20 -q >/dev/null 2>&1

n_win=$(grep -c "one turn minted three times" "$LLM_LOG" || true)
is "episode window reads the burst once beside the other run's copy" "2" "$n_win"
if grep -qF "x3 copies of this step collapsed" "$LLM_LOG"; then
    ok "the collapsed window line is marked with its copy count"
else
    bad "the collapsed window line is marked with its copy count" "$(grep -F 'minted' "$LLM_LOG" | head -2)"
fi
if grep -qF "stands for N adjacent identical raw rows" "$LLM_LOG"; then
    ok "the window prompt explains the mark"
else
    bad "the window prompt explains the mark" "no contract sentence in the system prompt"
fi
n_nr=$(grep -c "no run id at all" "$LLM_LOG" || true)
is "rows with no run id are not merged in the window" "2" "$n_nr"
EPS="$TRAJ_ROOT/deadbeef-root/recap/episodes.jsonl"
is "episode n_steps counts turns after the collapse" "7" "$(tail -1 "$EPS" | jq -r '.n_steps')"
is "episode raw line span still names the raw rows" "2" "$(tail -1 "$EPS" | jq -r '.raw_start_line')"

# ---------------------------------------------------------------------------
# Part B — the tier-1 rollup blocks (needs a full 10-row block)
# ---------------------------------------------------------------------------
mkest feedface-root 4
export LLM_LOG="$WORK/llm-b.log"
: > "$LLM_LOG"
recap feedface --traj_dir "$TRAJ_ROOT" --backfill >/dev/null 2>&1

n_t1=$(grep -c "one turn minted three times" "$LLM_LOG" || true)
is "tier-1 input reads the burst once beside the other run's copy" "2" "$n_t1"
if grep -qF "x3 copies of this step collapsed" "$LLM_LOG"; then
    ok "the collapsed tier-1 line is marked with its copy count"
else
    bad "the collapsed tier-1 line is marked with its copy count" "$(grep -F 'minted' "$LLM_LOG" | head -2)"
fi
if grep -qF "stands for N adjacent identical raw rows" "$LLM_LOG"; then
    ok "the rollup prompt explains the mark"
else
    bad "the rollup prompt explains the mark" "no contract sentence in the system prompt"
fi
BLK="$TRAJ_ROOT/feedface-root/rollups/t1/000000000000-000000000010.json"
is "the tier-1 block over the burst sealed" "1" "$(test -f "$BLK" && echo 1 || echo 0)"
is "sealed block stamped prompt_version 6" "6" "$(jq -r '.prompt_version' "$BLK" 2>/dev/null)"
TSV="$TRAJ_ROOT/feedface-root/rollups/rendered.tsv"
n_tsv=$(awk -F'\t' '$2=="bu1"||$2=="bu2"||$2=="bu3"' "$TSV" | wc -l | tr -d ' ')
is "rendered.tsv keeps all three copies" "3" "$n_tsv"
is "rendered.tsv carries the key column" "6" "$(sed -n '1p' "$TSV" | awk -F'\t' '{print NF}')"
is "render cache version bumped for the new columns" "2" "$(jq -r '.version' "$TRAJ_ROOT/feedface-root/rollups/rendered.meta.json" 2>/dev/null)"
is "no duplicate raw lines in the rebuilt cache" "" "$(cut -f1 "$TSV" | sort | uniq -d | head -1)"

# ---------------------------------------------------------------------------
# Part C — the raw tail of the context (a prompt-side render of TSV rows)
# ---------------------------------------------------------------------------
outc=$(recap feedface --traj_dir "$TRAJ_ROOT" --context --raw-tail 40 --cached 2>/dev/null || true)
n_rt=$(printf '%s\n' "$outc" | grep -c "one turn minted three times" || true)
is "context raw tail reads the burst once beside the other run's copy" "2" "$n_rt"
if printf '%s\n' "$outc" | grep -qF "x3 copies of this step collapsed"; then
    ok "the collapsed raw-tail line is marked with its copy count"
else
    bad "the collapsed raw-tail line is marked with its copy count" "$(printf '%s\n' "$outc" | grep -F 'minted' | head -2)"
fi

echo
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
