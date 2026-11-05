#!/usr/bin/env bash
# test_shellm_run_tmpdir.sh — every run gets its own TMPDIR under its run dir
#
# Usage: tests/test_shellm_run_tmpdir.sh
#
# `llm` is stubbed so the real run loop executes one block. The block calls
# `mktemp` and records TMPDIR. Both must point inside a shellm-run.* dir,
# and neither may survive the run (2026-09-17: a killed skill's mktemp
# copies of a 1.6 GB trajectory filled a box because wakes shared /tmp).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/script" "$WORK/home" "$WORK/wd"
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
# An ambient trajectory variable (any run inside shellm leaves these set:
# SHELLM_TRAJ_DIR outranks TRAJ_DIR, which outranks HEADLONG_HOME) would
# send the stub runs into the caller's real log. Neutralize all three
# before any nested exec.
unset TRAJ_DIR TRAJ_ID SHELLM_TRAJ_DIR
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local
: > "$LLM_COUNT"

TIMEOUT=""
for _t in timeout gtimeout; do
    if command -v "$_t" >/dev/null 2>&1; then TIMEOUT="$_t 120"; break; fi
done

fence() { printf '```bash\n%s\n```\n' "$1"; }
# Python's tempfile stands in for "any tool that honors TMPDIR": GNU mktemp
# on the boxes does, but macOS's BSD mktemp ignores TMPDIR without a template.
fence 'echo "$TMPDIR" > tmpdir_seen; python3 -c "import tempfile; print(tempfile.mkstemp()[1])" > tmpfile_seen' > "$WORK/script/1"
fence 'FINAL=done' > "$WORK/script/last"

( cd "$WORK/wd" && $TIMEOUT "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 2 "tmpdir case" ) \
    > "$WORK/out" 2> "$WORK/err" < /dev/null

# Collapse doubled slashes: macOS sets TMPDIR with a trailing slash, and
# Python normalizes the path while the shell keeps it verbatim.
seen=$(sed 's#//*#/#g' "$WORK/wd/tmpdir_seen" 2>/dev/null || true)
tmpfile=$(sed 's#//*#/#g' "$WORK/wd/tmpfile_seen" 2>/dev/null || true)

case "$seen" in
    */shellm-run.*/tmp) ok "TMPDIR is <rundir>/tmp ($seen)" ;;
    *) bad "TMPDIR is <rundir>/tmp" "seen='$seen' err=$(tail -3 "$WORK/err")" ;;
esac
case "$tmpfile" in
    "$seen"/*) ok "a temp file made in the block lands under TMPDIR" ;;
    *) bad "a temp file made in the block lands under TMPDIR" "tmpfile='$tmpfile'" ;;
esac
[[ -n "$seen" && ! -e "$seen" ]] && ok "run TMPDIR is gone after the run" || bad "run TMPDIR is gone after the run"
[[ -n "$tmpfile" && ! -e "$tmpfile" ]] && ok "the block's temp file is gone after the run" || bad "the block's temp file is gone after the run"
grep -qx 'done' "$WORK/out" && ok "run still finishes with its final" || bad "run still finishes with its final" "$(tail -3 "$WORK/err")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
