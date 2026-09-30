#!/usr/bin/env bash
# test_shellm_resume_guard.sh — a nested run must not --resume the live trajectory
#
# Usage: tests/test_shellm_resume_guard.sh
#
# Why: generated code calling shellm inherits the parent run's TRAJ_DIR, so
# a bare `shellm --resume` inside a block resolved "latest" to the parent's
# own live trajectory and appended foreign rows to it (2026-09-30: 27 such
# rows landed in a live identity log this way). The guard refuses a bare
# --resume inside a nested run unless the caller names the target
# (--traj ID) or re-roots the directory (--traj-dir).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub: script/1 for the parent's first call, FINAL=done otherwise ---
mkdir -p "$WORK/home" "$WORK/wd" "$WORK/other-trajs" "$WORK/script"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=$(( $(cat "$LLM_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$LLM_COUNT"
if [[ -f "$LLM_SCRIPT/$n" ]]; then cat "$LLM_SCRIPT/$n"; else cat "$LLM_SCRIPT/last"; fi
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export LLM_COUNT="$WORK/count"
export LLM_SCRIPT="$WORK/script"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local
: > "$LLM_COUNT"
# The suite may itself run inside a shellm run; the top-level case needs a
# clean slate.
unset SHELLM_RUN_STEP_ID || true

TIMEOUT=""
for _t in timeout gtimeout; do
    if command -v "$_t" >/dev/null 2>&1; then TIMEOUT="$_t 300"; break; fi
done

fence() { printf '```bash\n%s\n```\n' "$1"; }

run_shellm() {
    ( cd "$WORK/wd" && $TIMEOUT "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 2 "$@" ) \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# --- 1. the parent run: its block makes every nested call shape -------------
OTHER="$WORK/other-trajs"
block="if shellm --traj-dir $OTHER seed > seed.out 2> seed.err; then echo 0 > seed.rc; else echo \$? > seed.rc; fi
if shellm --resume nested > bare.out 2> bare.err; then echo 0 > bare.rc; else echo \$? > bare.rc; fi
if shellm --resume --traj-dir $OTHER nested > dir.out 2> dir.err; then echo 0 > dir.rc; else echo \$? > dir.rc; fi
if shellm --traj no-such-traj nested > traj.out 2> traj.err; then echo 0 > traj.rc; else echo \$? > traj.rc; fi
FINAL=parent-done"
fence "$block" > "$WORK/script/1"
fence 'FINAL=done' > "$WORK/script/last"

run_shellm "parent run"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -qx 'parent-done' "$WORK/out"; then
    ok "parent run completes (rc=$rc)"
else
    bad "parent run completes" "rc=$rc $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

# --- 2. nested bare --resume is refused --------------------------------------
if [[ "$(cat "$WORK/wd/bare.rc" 2>/dev/null)" != "0" ]] \
   && grep -q 'inside a nested run' "$WORK/wd/bare.err" 2>/dev/null; then
    ok "nested bare --resume refused: $(head -1 "$WORK/wd/bare.err")"
else
    bad "nested bare --resume refused" "rc=$(cat "$WORK/wd/bare.rc" 2>/dev/null) $(head -1 "$WORK/wd/bare.err" 2>/dev/null)"
fi

# --- 3. nested --resume with an explicit --traj-dir proceeds -----------------
if [[ "$(cat "$WORK/wd/dir.rc" 2>/dev/null)" == "0" ]] \
   && grep -qx 'done' "$WORK/wd/dir.out" 2>/dev/null; then
    ok "nested --resume --traj-dir proceeds and finishes"
else
    bad "nested --resume --traj-dir proceeds" "rc=$(cat "$WORK/wd/dir.rc" 2>/dev/null) $(tail -1 "$WORK/wd/dir.err" 2>/dev/null)"
fi

# --- 4. nested --traj skips the guard (later checks apply) -------------------
if [[ "$(cat "$WORK/wd/traj.rc" 2>/dev/null)" != "0" ]] \
   && grep -q 'Cannot find trajectory' "$WORK/wd/traj.err" 2>/dev/null \
   && ! grep -q 'inside a nested run' "$WORK/wd/traj.err" 2>/dev/null; then
    ok "nested --traj is not blocked by the guard (fails on the id instead)"
else
    bad "nested --traj is not blocked by the guard" "rc=$(cat "$WORK/wd/traj.rc" 2>/dev/null) $(head -1 "$WORK/wd/traj.err" 2>/dev/null)"
fi

# --- 5. nested runs without --resume are unaffected --------------------------
if [[ "$(cat "$WORK/wd/seed.rc" 2>/dev/null)" == "0" ]]; then
    ok "nested run without --resume still works"
else
    bad "nested run without --resume still works" "rc=$(cat "$WORK/wd/seed.rc" 2>/dev/null) $(tail -1 "$WORK/wd/seed.err" 2>/dev/null)"
fi

# --- 6. top-level --resume is unaffected --------------------------------------
run_shellm --resume "top level"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -qx 'done' "$WORK/out"; then
    ok "top-level --resume still works (rc=$rc)"
else
    bad "top-level --resume still works" "rc=$rc $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
