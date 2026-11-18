#!/usr/bin/env bash
# Usage: tests/test_rollup_atomic_publication.sh
# Inject failures only at the sealed-block writer in an isolated CLI fixture.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
TEMP_ROOT=$(mktemp -d); trap 'rm -rf "$TEMP_ROOT"' EXIT
# A tier-looking ancestor must never be counted as a sealed-block directory.
WORK="$TEMP_ROOT/t1-fixture"
mkdir -p "$WORK/bin" "$WORK/home"
REAL_JQ=$(command -v jq)
export REAL_JQ HOME="$WORK/home" HEADLONG_HOME="$WORK/home" SHELLM_ENV=local
export PATH="$WORK/bin:$REPO/bin:$PATH" CALLS="$WORK/calls" FAULT="$WORK/fault"
unset TRAJ_DIR TRAJ_ID IDENTITY_DIR ROLLUP_MAX_SEALS ROLLUP_FANOUT LLM_FAIL 2>/dev/null || true
cat > "$WORK/bin/llm" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'call\n' >> "$CALLS"
if [[ "${LLM_FAIL:-0}" == 1 ]]; then
    printf 'llm: error: empty response\n' >&2
    exit 1
fi
printf '{"summary":"fixture","themes":[],"step_ids":[]}'
EOF
cat > "$WORK/bin/jq" <<'EOF'
#!/usr/bin/env bash
prev=""; before=""; tier=""
for arg in "$@"; do
    [[ "$before" == --argjson && "$prev" == tier ]] && tier="$arg"
    before="$prev"; prev="$arg"
done
if [[ -f "$FAULT" && "$tier" == "$FAULT_TIER" ]]; then
    case "$FAULT_MODE" in
        partial) printf '{"tier":'; exit 77 ;;
        empty) exit 77 ;;
        invalid) printf '{}'; exit 0 ;;
    esac
fi
exec "$REAL_JQ" "$@"
EOF
chmod +x "$WORK/bin/llm" "$WORK/bin/jq"
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
fixture() {
    run="$WORK/trajectories/feedbeef-root"
    rm -rf "$WORK/trajectories"; mkdir -p "$run"
    for ((i=0; i<4; i++)); do
        printf '{"type":"thought","step_id":"s%s","ts":"2026-11-14T00:00:00Z","content":"fixture %s"}\n' "$i" "$i"
    done > "$run/trajectory.jsonl"
    : > "$CALLS"
}
ctx() { "$REPO/bin/recap" feedbeef --traj_dir "$WORK/trajectories" --context --backfill --fanout 2 --raw-tail 1 > "$WORK/context" 2> "$WORK/stderr"; }
blockfiles() {
    local dir
    for dir in "$run/rollups"/t[0-9]*; do
        [[ -d "$dir" ]] || continue
        find "$dir" -type f -name '*.json' -print
    done
    return 0
}
for FAULT_TIER in 1 2; do
    export FAULT_TIER
    for FAULT_MODE in partial empty invalid; do
        export FAULT_MODE; fixture; touch "$FAULT"
        rc=0; ctx || rc=$?
        published=$(find "$run/rollups/t$FAULT_TIER" -name "*.json" -print 2>/dev/null)
        if [[ -z "$published" && "$rc" == 0 && -s "$WORK/context" ]]; then ok "t$FAULT_TIER $FAULT_MODE not published; partial output retained"; else bad "t$FAULT_TIER $FAULT_MODE not published; partial output retained"; fi
        if [[ -z "$(find "$run/rollups" -name '*.tmp.*' -print)" ]]; then ok "t$FAULT_TIER $FAULT_MODE handled failure cleans staging"; else bad "t$FAULT_TIER $FAULT_MODE handled failure cleans staging"; fi
        if grep -q "rollup t$FAULT_TIER .*stopping the build" "$WORK/stderr"; then ok "t$FAULT_TIER $FAULT_MODE stop is reported"; else bad "t$FAULT_TIER $FAULT_MODE stop is reported"; fi
        before=$(wc -l < "$CALLS" | tr -d ' '); rm -f "$FAULT"; ctx
        after=$(wc -l < "$CALLS" | tr -d ' ')
        files=$(blockfiles)
        valid=1
        while IFS= read -r file; do
            "$REAL_JQ" -e 'type == "object" and (.summary | type == "string")' "$file" >/dev/null 2>&1 || valid=0
        done <<< "$files"
        if [[ "$after" -gt "$before" && "$valid" == 1 && "$(printf '%s\n' "$files" | wc -l | tr -d ' ')" == 3 ]]; then ok "t$FAULT_TIER $FAULT_MODE retry seals valid blocks"; else bad "t$FAULT_TIER $FAULT_MODE retry seals valid blocks"; fi
        before="$after"; ctx; after=$(wc -l < "$CALLS" | tr -d ' ')
        [[ "$before" == "$after" ]] && ok 'sealed cache is reused' || bad 'sealed cache is reused'
    done
done
fixture
export LLM_FAIL=1
rc=0; ctx || rc=$?
published=$(blockfiles)
if [[ -z "$published" && "$rc" == 0 && -s "$WORK/context" ]]; then ok 'empty model failure leaves no block and preserves partial context'; else bad 'empty model failure leaves no block and preserves partial context'; fi
if grep -q 'stopping the build' "$WORK/stderr"; then ok 'empty model failure reports stopping on every jq version'; else bad 'empty model failure reports stopping on every jq version'; fi
unset LLM_FAIL
ctx
[[ "$(blockfiles | wc -l | tr -d ' ')" == 3 ]] && ok 'empty model failure retries successfully on the next call' || bad 'empty model failure retries successfully on the next call'
fixture
mkdir -p "$run/rollups/t1"; : > "$run/rollups/t1/000000000000-000000000002.json"
ctx
if "$REAL_JQ" -e '.summary == "fixture"' "$run/rollups/t1/000000000000-000000000002.json" >/dev/null 2>&1; then ok 'zero-byte cache is retried'; else bad 'zero-byte cache is retried'; fi
fixture
mkdir -p "$run/rollups/t1"; printf 'existing-corrupt' > "$run/rollups/t1/000000000000-000000000002.json"
ctx
[[ "$(cat "$run/rollups/t1/000000000000-000000000002.json")" == existing-corrupt ]] && ok 'nonempty corrupt-cache policy unchanged' || bad 'nonempty corrupt-cache policy unchanged'
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
