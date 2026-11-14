#!/usr/bin/env bash
# test_recap_render_cut_marker.sh — the recap render's 500-char row cut is marked
#
# Usage: tests/test_recap_render_cut_marker.sh
#
# _render_steps caps every non-shellm-run row at 500 chars of text. The cap
# is load-bearing (_ctx_resolve_R budgets the raw tail from this 500-char
# worst case), but the cut was silent: a sealed tier block could inherit a
# half sentence as if it were the step's whole content, and a wake reading
# a rendered row had no sign the text continued. This pins the cut-marker
# family's recap render site (PRs 218, 230, 231 and 236 fixed the
# wake-prompt and store sites):
#   - a cut row ends with "(+N more: full step in the raw log)" naming the
#     dropped character count,
#   - a row that fits renders whole with no marker,
#   - the dropped text is absent from the cache,
#   - both summarizer prompts (window and rollup) say a marked line is a
#     partial row, so no consumer reads a cut as the step's ending,
#   - the render format version bumps to 2, so stale caches rebuild.
#
# The `llm` CLI is stubbed (canned JSON, argv and stdin logged): no network.
#
# Red on the unmodified base (marker, prompt and version arms), green at
# the fix.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check()     { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }
eq()  { local label="$1" got="$2" want="$3"; if [[ "$got" == "$want" ]]; then ok "$label"; else bad "$label" "got [${got:0:80}...] want [${want:0:80}...]"; fi; }

# --- stub llm: canned JSON, argv and stdin logged ------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
{ printf 'CALL\n'; printf 'ARGV %s\n' "$*"; printf -- '---INPUT---\n'; printf '%s\n' "$input"; printf -- '---END---\n'; } >> "$LLM_LOG"
if printf '%s' "$input" | grep -q '^EPISODE '; then
    printf '{"arc":"the agent worked","themes":[]}'
else
    first=$(printf '%s' "$input" | grep -o '\[[0-9a-z?]\{1,8\}\]' | head -1 | tr -d '[]')
    printf '{"title":"w","summary":"did things","themes":["t"],"notable_steps":[{"step":"%s","note":"n"}]}' "${first:-x1}"
fi
EOF
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export LLM_LOG="$WORK/llm.log"

unset TRAJ_DIR TRAJ_ID RECAP_MODEL SHELLM_FAST_MODEL SHELLM_MODEL 2>/dev/null || true

# --- synthetic log: 4 pinned rows + 26 fillers = 3 full tier-1 blocks ---
TRAJ_ROOT="$WORK/trajectories"
RUN="$TRAJ_ROOT/mark0001-root"
mkdir -p "$RUN"
JSONL="$RUN/trajectory.jsonl"
printf '{"type":"trajectory","step_id":"mark0001-0000-4000-8000-000000000000","ts":"t0"}\n' > "$JSONL"

# exactly 500 visible chars: renders whole, no marker
fit=$(printf 'a%.0s' $(seq 1 500))
# 745 visible chars: 500 kept, the rest dropped, sentinel inside the drop
cut=$(printf 'b%.0s' $(seq 1 500))$(printf 'c%.0s' $(seq 1 229))ZZSENTINELTAIL14
# dropped count computed from the fixture, never hand-summed
dropped=$(( ${#cut} - 500 ))
marker="(+${dropped} more: full step in the raw log)"
printf '{"type":"thought","step_id":"fit00001","ts":"2026-07-17T10:01:00","source":"tester","content":"%s"}\n' "$fit" >> "$JSONL"
printf '{"type":"thought","step_id":"cut00001","ts":"2026-07-17T10:02:00","source":"tester","content":"%s"}\n' "$cut" >> "$JSONL"
printf '{"type":"thought","step_id":"sht00001","ts":"2026-07-17T10:03:00","source":"tester","content":"tiny thought"}\n' >> "$JSONL"
printf '{"type":"shellm-run","step_id":"run00001","ts":"2026-07-17T10:04:00","source":"tester","wake":"timer","model":"m","launched_by":"monolith","command":"x"}\n' >> "$JSONL"
for i in $(seq 1 26); do
    printf '{"type":"thought","step_id":"fil%06d","ts":"2026-07-17T11:%02d:00","source":"tester","content":"filler step %d"}\n' \
        "$i" $((i % 60)) "$i" >> "$JSONL"
done

TSV="$RUN/rollups/rendered.tsv"
META="$RUN/rollups/rendered.meta.json"
row() { awk -F'\t' -v id="$1" '$2==id{print $4; exit}' "$TSV"; }

# --- context run: renders, seals tier 1, logs the rollup call ------------
recap mark0001 --traj_dir "$TRAJ_ROOT" --context --raw-tail 5 -q >/dev/null 2>&1
check "context run succeeds" test -s "$TSV"

eq "fixture arithmetic sane"               "$dropped" "245"
eq "fit row renders whole, no marker"      "$(row fit00001)" "[fit00001] thought(tester): $fit"
eq "cut row carries the marker"            "$(row cut00001)" "[cut00001] thought(tester): ${cut:0:500} $marker"
eq "short row has no marker"               "$(row sht00001)" "[sht00001] thought(tester): tiny thought"
eq "shellm-run row takes no marker path"   "$(row run00001)" "[run00001] shellm-run(tester): wake timer, model m"
check_not "dropped text absent from the cache" grep -q ZZSENTINELTAIL14 "$TSV"
eq "render format version bumped to 2" "$(jq -r '.version // empty' "$META" 2>/dev/null)" "2"

# --- backfill leg: the first --context run snaps the start marker and seals
# nothing (pinned by test_recap_context_upgrade), so the rollup build is
# reached through --backfill, which seals tier 1 over the rendered rows ----
: > "$LLM_LOG"
recap mark0001 --traj_dir "$TRAJ_ROOT" --backfill -q >/dev/null 2>&1
check "backfill seals tier 1"            test -n "$(ls "$RUN/rollups/t1" 2>/dev/null)"
check "rollup input carries the marked row"  grep -qF "$marker" "$LLM_LOG"
check "rollup prompt names the cut row" \
    sh -c "awk '/^ARGV/ && /-t 4096/ && /is a cut row/' '$LLM_LOG' | grep -q ."

# --- episodes run: the window summarizer gets the same marked row ---------
: > "$LLM_LOG"
recap mark0001 --traj_dir "$TRAJ_ROOT" --window 20 -q >/dev/null 2>&1
check "window input carries the marked row"  grep -qF "$marker" "$LLM_LOG"
check "window prompt names the cut row" \
    sh -c "awk '/^ARGV/ && /-t 2048/ && /is a cut row/' '$LLM_LOG' | grep -q ."

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
