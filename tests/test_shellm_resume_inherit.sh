#!/usr/bin/env bash
# test_shellm_resume_inherit.sh — resume inherits workdir/env past the 50-record window
#
# Usage: tests/test_shellm_resume_inherit.sh
#
# Why: --traj/--resume inherited workdir, env and docker image by reading the
# trajectory's shellm-run row out of the LAST 50 records. That row is minted
# at run start, so a trajectory with more than ~50 records since the run
# began no longer contained it, and resume silently fell back to a fresh
# workdir under the workdirs root: a resumed run drifted out of its
# workspace with no warning. The scan now reads the whole file, last match
# wins. This builds a real trajectory with a shellm-run row followed by 60
# filler records, resumes it with a stubbed llm, and checks the launcher
# reports the original workdir; plus the same path with an empty trajectory,
# a corrupt line, and explicit --workdir still overriding.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s %s\n' "$1" "${2:-}"; }

# --- stub toolchain --------------------------------------------------------
mkdir -p "$WORK/home" "$WORK/wd" "$WORK/msgs" "$WORK/trajectories"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
main_loop=0; mf=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --thinking) main_loop=1; shift ;;
        --messages-file) mf="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$main_loop" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=$(ls "$LLM_STUB_DIR" 2>/dev/null | grep -c "^call-.*json$" || true)
n=${n:-0}
cp "$mf" "$LLM_STUB_DIR/call-$((n + 1)).json"
printf '```bash\nFINAL=done\n```\n'
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local
export SHELLM_TRAJ_DIR="$WORK/trajectories"
export LLM_STUB_DIR="$WORK/msgs"
export SHELLM_INACTIVITY_TIMEOUT=60

WORKDIR_A="$WORK/inherited-wd"
mkdir -p "$WORKDIR_A"

run_shellm() {
    ( cd "$WORK/wd" && "$WORK/toolbin/shellm" --max-iterations 1 "$@" ) \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
    cat "$WORK/out" "$WORK/err" > "$WORK/log"
}

row() {  # row TYPE STEP_SUFFIX [WORKDIR]
    printf '{"type":"%s","command":"stub"%s,"model":"m","env":{"name":"local","type":"local"},"resumed":false,"step_id":"00000000-0000-0000-0000-%012d","ts":"2026-09-30T00:00:01Z"}\n' \
        "$1" "${3:+,\"workdir\":\"$3\"}" "$2"
}

# --- 1. the window: 60 filler rows past the shellm-run row ------------------
TID="11111111-1111-1111-1111-111111111111"
mkdir -p "$WORK/trajectories/11111111-window"
F="$WORK/trajectories/11111111-window/trajectory.jsonl"
printf '{"type":"trajectory","step_id":"00000000-0000-0000-0000-000000000001","ts":"2026-09-30T00:00:00Z"}\n' > "$F"
row shellm-run 2 "$WORKDIR_A" >> "$F"
i=3
while (( i < 63 )); do
    printf '{"type":"reasoning","content":"filler","step_id":"00000000-0000-0000-0000-%012d","ts":"2026-09-30T00:00:10Z"}\n' "$i" >> "$F"
    (( i++ ))
done
run_shellm --traj "$TID" "do nothing"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "Workdir: .*inherited-wd" "$WORK/log"; then
    ok "resume finds the workdir past 60 records (rc=$rc)"
else
    bad "resume finds the workdir past 60 records" "rc=$rc $(tail -n 2 "$WORK/err" | tr '\n' ' ')"
fi

# --- 2. no shellm-run row: resume still runs, nothing inherited -------------
TID2="22222222-2222-2222-2222-222222222222"
mkdir -p "$WORK/trajectories/22222222-empty"
printf '{"type":"trajectory","step_id":"00000000-0000-0000-0000-00000000000a","ts":"2026-09-30T00:00:00Z"}\n' \
    > "$WORK/trajectories/22222222-empty/trajectory.jsonl"
run_shellm --traj "$TID2" "do nothing"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "Using trajectory: 22222222" "$WORK/log"; then
    ok "a trajectory with no shellm-run row resumes cleanly (rc=$rc)"
else
    bad "a trajectory with no shellm-run row resumes cleanly" "rc=$rc $(tail -n 2 "$WORK/err" | tr '\n' ' ')"
fi

# --- 3. a corrupt line must not break inheritance or the run ----------------
TID3="33333333-3333-3333-3333-333333333333"
mkdir -p "$WORK/trajectories/33333333-corrupt"
{
    printf '{"type":"trajectory","step_id":"00000000-0000-0000-0000-00000000000b","ts":"2026-09-30T00:00:00Z"}\n'
    printf 'THIS LINE IS NOT JSON\n'
    row shellm-run 99 "$WORKDIR_A"
} > "$WORK/trajectories/33333333-corrupt/trajectory.jsonl"
run_shellm --traj "$TID3" "do nothing"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "Workdir: .*inherited-wd" "$WORK/log"; then
    ok "a corrupt line before the row does not break inheritance (rc=$rc)"
else
    bad "a corrupt line before the row does not break inheritance" "rc=$rc $(tail -n 2 "$WORK/err" | tr '\n' ' ')"
fi

# --- 4. explicit --workdir still wins ---------------------------------------
run_shellm --traj "$TID" --workdir "$WORK/other-wd" "do nothing"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "Workdir: .*other-wd" "$WORK/log" && ! grep -q "Workdir: .*inherited-wd" "$WORK/log"; then
    ok "explicit --workdir overrides the inherited one (rc=$rc)"
else
    bad "explicit --workdir overrides the inherited one" "rc=$rc $(tail -n 2 "$WORK/err" | tr '\n' ' ')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
