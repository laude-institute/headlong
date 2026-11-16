#!/usr/bin/env bash
# Usage: tests/test_recap_response_validation.sh
# Validate the real recap JSON reader and its printable-partial CLI behavior.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"
export HOME="$WORK/home" HEADLONG_HOME="$WORK/home" SHELLM_ENV=local
export PATH="$WORK/bin:$REPO/bin:$PATH" REPLY="$WORK/reply" CALLS="$WORK/calls"
unset TRAJ_DIR TRAJ_ID IDENTITY_DIR RECAP_MODEL SHELLM_MODEL ROLLUP_MODEL 2>/dev/null || true
cat > "$WORK/bin/llm" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'call\n' >> "$CALLS"
if [[ "${REFUSAL:-0}" == 1 ]]; then printf 'llm: refused: fixture\n' >&2; exit 1; fi
model=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) model="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$model" == episode-fixture ]]; then
    printf '{"title":"fixture","summary":"fixture","themes":[],"notable_steps":[]}'
    exit 0
fi
cat "$REPLY"
EOF
chmod +x "$WORK/bin/llm"
sed -n '/^_llm_json() {$/,/^}$/p' "$REPO/bin/recap" > "$WORK/reader"
# shellcheck disable=SC1091
source "$WORK/reader"
note() { printf '%s\n' "$*" >&2; }
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
for shape in empty whitespace array null string number multiple malformed valid fenced; do
    case "$shape" in
        empty) : > "$REPLY" ;;
        whitespace) printf ' \n\t ' > "$REPLY" ;;
        array) printf '[]' > "$REPLY" ;;
        null) printf 'null' > "$REPLY" ;;
        string) printf '"text"' > "$REPLY" ;;
        number) printf '7' > "$REPLY" ;;
        multiple) printf '{}\n{}\n' > "$REPLY" ;;
        malformed) printf '{broken' > "$REPLY" ;;
        valid) printf '{"summary":"fixture","themes":[],"step_ids":[]}' > "$REPLY" ;;
        fenced) printf '```json\n{"summary":"fixture"}\n```\n' > "$REPLY" ;;
    esac
    : > "$CALLS"; rc=0
    result=$(_llm_json fixture system input 256 2>"$WORK/stderr") || rc=$?
    count=$(wc -l < "$CALLS" | tr -d ' ')
    if [[ "$shape" == valid || "$shape" == fenced ]]; then
        expected='{"summary":"fixture","themes":[],"step_ids":[]}'
        [[ "$shape" == fenced ]] && expected='{"summary":"fixture"}'
        if [[ "$rc" == 0 && "$count" == 1 && "$result" == "$expected" ]]; then ok "$shape returned unchanged without fences in one attempt"; else bad "$shape returned unchanged without fences in one attempt"; fi
    else
        if [[ "$rc" != 0 && "$count" == 2 && -z "$result" ]] && grep -q 'did not return a single JSON object' "$WORK/stderr"; then ok "$shape rejected after two attempts with a shape diagnostic"; else bad "$shape rejected after two attempts with a shape diagnostic"; fi
    fi
done
export REFUSAL=1
rc=0; _llm_json fixture system input 256 >/dev/null 2>"$WORK/stderr" || rc=$?
[[ "$rc" == 2 ]] && ok 'refusal status remains 2' || bad 'refusal status remains 2'
unset REFUSAL

# Real CLI: an unusable reply leaves the frontier unsealed and still prints
# the raw/partial context with the established successful exit status.
mkdir -p "$WORK/trajectories/feedbeef-root"
for ((i=0; i<15; i++)); do
    printf '{"type":"thought","step_id":"s%s","ts":"2026-11-14T00:00:00Z","content":"fixture %s"}\n' "$i" "$i"
done > "$WORK/trajectories/feedbeef-root/trajectory.jsonl"
: > "$REPLY"
rc=0
"$REPO/bin/recap" feedbeef --traj_dir "$WORK/trajectories" --context --backfill --raw-tail 1 > "$WORK/context" 2> "$WORK/stderr" || rc=$?
if [[ "$rc" == 0 && -s "$WORK/context" ]] && grep -q 'no valid JSON' "$WORK/stderr" && [[ -z "$(find "$WORK/trajectories" -path '*/rollups/t[0-9]*/*.json' -print)" ]]; then
    ok 'CLI keeps partial output and no sealed invalid block'
else bad 'CLI keeps partial output and no sealed invalid block'; fi

# Plain recap must reject unusable episode/theme replies before writing the
# corresponding cache. A later valid response must recover without rebuilding.
cache="$WORK/trajectories/feedbeef-root/recap"
for stage in episode theme; do
    for shape in empty array; do
        rm -rf "$cache"
        : > "$CALLS"
        case "$shape" in empty) : > "$REPLY" ;; array) printf '[]' > "$REPLY" ;; esac
        map_model=invalid-fixture
        [[ "$stage" == theme ]] && map_model=episode-fixture
        rc=0
        "$REPO/bin/recap" feedbeef --traj_dir "$WORK/trajectories" --window 15 --map-model "$map_model" --reduce-model theme-fixture --json > "$WORK/recap" 2> "$WORK/stderr" || rc=$?
        count=$(wc -l < "$CALLS" | tr -d ' ')
        if [[ "$stage" == episode ]]; then
            if [[ "$rc" != 0 && "$count" == 2 && ! -s "$cache/episodes.jsonl" && ! -e "$cache/themes.json" ]] && grep -q 'episode 1: model did not produce valid JSON' "$WORK/stderr"; then
                ok "$shape episode rejected without a cache entry"
            else bad "$shape episode rejected without a cache entry"; fi
        else
            if [[ "$rc" != 0 && "$count" == 3 && ! -e "$cache/themes.json" ]] && jq -se 'length == 1 and .[0].summary == "fixture"' "$cache/episodes.jsonl" >/dev/null && grep -q 'theme reduction: model did not produce valid JSON' "$WORK/stderr"; then
                ok "$shape theme rejected while the valid episode is kept"
            else bad "$shape theme rejected while the valid episode is kept"; fi
        fi
        printf '{"title":"fixture","summary":"fixture","themes":[],"notable_steps":[],"arc":"recovered"}' > "$REPLY"
        : > "$CALLS"; rc=0
        "$REPO/bin/recap" feedbeef --traj_dir "$WORK/trajectories" --window 15 --map-model "$map_model" --reduce-model theme-fixture --json > "$WORK/recap" 2> "$WORK/stderr" || rc=$?
        count=$(wc -l < "$CALLS" | tr -d ' ')
        expected_calls=2
        [[ "$stage" == theme ]] && expected_calls=1
        if [[ "$rc" == 0 && "$count" == "$expected_calls" ]] && jq -e '.themes.arc == "recovered" and (.episodes | length == 1) and .episodes[0].summary == "fixture"' "$WORK/recap" >/dev/null; then
            ok "$shape $stage failure recovers without rebuilding valid episodes"
        else bad "$shape $stage failure recovers without rebuilding valid episodes"; fi
    done
done
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
