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
        if [[ "$rc" == 0 && "$count" == 1 ]] && printf '%s' "$result" | jq -e 'type == "object"' >/dev/null; then ok "$shape accepted once"; else bad "$shape accepted once"; fi
    else
        if [[ "$rc" != 0 && "$count" == 2 && -z "$result" ]]; then ok "$shape rejected after two attempts"; else bad "$shape rejected after two attempts"; fi
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
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
