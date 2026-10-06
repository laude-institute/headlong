#!/usr/bin/env bash
# tests/test_explore_report_argv.sh — the report prompt stays off argv.
#
# Usage: tests/test_explore_report_argv.sh
#
# `shellm-explore --report` builds a prompt out of every run's context in the
# tree. Nothing that can hold it may travel through argv: Linux caps a single
# argument at 128 KiB and macOS caps total argv at 1 MiB, so a tree with a
# large recorded command used to die with "Argument list too long" (rc=126)
# before the model was ever called.
#
# The fixture is one run whose `command` holds a 200 KiB inline prompt — the
# same shape that put --prompt-file into bin/shellm. `llm` is stubbed and
# reports what it was handed, so the check is platform-independent: the
# prompt arrives on stdin and argv stays small.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/bin" "$WORK/traj/abc12345-run"

big=$(head -c 204800 /dev/zero | tr '\0' 'x')
{
    printf '{"type":"shellm-run","step_id":"s1","command":"shellm %s"}\n' "$big"
    printf '{"type":"run-summary","tldr":"a run with a large inline prompt MARKER-abc12345"}\n'
} > "$WORK/traj/abc12345-run/trajectory.jsonl"

# The stub records argv and stdin verbatim as well as their sizes: byte counts
# alone would stay green with the system prompt dropped or the prompt cut off.
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${LLM_ARGV_FILE:?}"
argv_bytes=0
for a in "$@"; do argv_bytes=$((argv_bytes + ${#a})); done
if [[ -t 0 ]]; then stdin_bytes=0; else s=$(cat); stdin_bytes=${#s}; fi
printf '%s' "${s:-}" > "${LLM_STDIN_FILE:?}"
printf 'argv=%d stdin=%d\n' "$argv_bytes" "$stdin_bytes" >&2
printf 'a report\n'
STUB
chmod +x "$WORK/bin/llm"

# env -u: the tool resolves SHELLM_TRAJ_DIR before TRAJ_DIR, and SHELLM_HOME /
# HEADLONG_HOME / SHELLM_MODEL all steer it — any of them inherited from the
# calling shell would fail this test for the wrong reason.
env -u SHELLM_TRAJ_DIR -u SHELLM_HOME -u HEADLONG_HOME -u SHELLM_MODEL \
    PATH="$WORK/bin:$PATH" TRAJ_DIR="$WORK/traj" \
    LLM_ARGV_FILE="$WORK/argv.txt" LLM_STDIN_FILE="$WORK/stdin.txt" \
    bash "$REPO/tools/shellm-explore" abc12345 --report \
    > "$WORK/out" 2> "$WORK/err"
rc=$?

[[ "$rc" -eq 0 ]] \
    && ok "report survives a 200 KiB recorded command" \
    || bad "report survives a 200 KiB recorded command" "rc=$rc: $(tail -1 "$WORK/err")"

seen=$(grep -o 'argv=[0-9]* stdin=[0-9]*' "$WORK/err" | tail -1)
argv_bytes=${seen#argv=}; argv_bytes=${argv_bytes%% *}
stdin_bytes=${seen##*stdin=}

[[ -n "$seen" && "$argv_bytes" -lt 4096 ]] \
    && ok "llm argv stays small (${argv_bytes:-?} bytes)" \
    || bad "llm argv stays small" "${seen:-llm was never reached}"

[[ -n "$seen" && "$stdin_bytes" -gt 204800 ]] \
    && ok "the prompt reaches llm on stdin (${stdin_bytes:-?} bytes)" \
    || bad "the prompt reaches llm on stdin" "${seen:-llm was never reached}"

grep -q 'a report' "$WORK/out" \
    && ok "the report is printed" \
    || bad "the report is printed" "$(tail -1 "$WORK/out")"

# Content, not just shape: the flags survive and the prompt arrives whole
# enough to carry the fixture's own words.
grep -qx -- '-s' "$WORK/argv.txt" 2>/dev/null \
    && ok "the system prompt flag is passed" \
    || bad "the system prompt flag is passed" "argv: $(tr '\n' ' ' < "$WORK/argv.txt" 2>/dev/null | cut -c1-120)"
grep -qx -- '-m' "$WORK/argv.txt" 2>/dev/null \
    && ok "the model flag is passed" \
    || bad "the model flag is passed" "argv: $(tr '\n' ' ' < "$WORK/argv.txt" 2>/dev/null | cut -c1-120)"
grep -q 'MARKER-abc12345' "$WORK/stdin.txt" 2>/dev/null \
    && ok "the run summary reaches llm inside the stdin prompt" \
    || bad "the run summary reaches llm inside the stdin prompt" "marker missing from stdin capture"

# Tree paths are canonicalized for cycle detection. The selected run must
# still match when the trajectory directory is relative or contains a symlink.
ln -s "$WORK/traj" "$WORK/traj-link"
for traj_dir in traj "$WORK/traj-link/"; do
    for mode in tree report; do
        args=()
        [[ "$mode" == report ]] && args+=(--report)
        : > "$WORK/stdin.txt"
        (
            cd "$WORK" || exit 1
            env -u SHELLM_TRAJ_DIR -u SHELLM_HOME -u HEADLONG_HOME -u SHELLM_MODEL \
                PATH="$WORK/bin:$PATH" \
                LLM_ARGV_FILE="$WORK/argv.txt" LLM_STDIN_FILE="$WORK/stdin.txt" \
                bash "$REPO/tools/shellm-explore" abc12345 --traj-dir "$traj_dir" \
                "${args[@]+"${args[@]}"}" > "$WORK/out" 2> "$WORK/err"
        )
        rc=$?
        captured="$WORK/out"
        [[ "$mode" == report ]] && captured="$WORK/stdin.txt"
        if [[ "$rc" -eq 0 && "$(grep -c '^>>> abc12345:' "$captured")" == 1 ]]; then
            ok "$mode retains selected run for $traj_dir"
        else
            bad "$mode retains selected run for $traj_dir" "rc=$rc, selected run marker missing"
        fi
    done
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
