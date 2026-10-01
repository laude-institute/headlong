#!/usr/bin/env bash
# tests/test_xtrace_fd.sh - regression: the trace channel is a seam, not a
# filter. On bash 4.1+ the wrapper opens fd 9 on a trace file and points
# BASH_XTRACEFD at it before `set -x`, so xtrace never shares the captured
# output stream: a traced multiline argument leaves no prefix-less
# continuation lines in the captured stream and cannot glue onto an
# unterminated output line. PS4 keeps the \001 mark and the storage strip
# remains the fallback for bash 3.2 and for a generated block that closes
# fd 9, where marked trace returns to stderr. Known boundary, documented and
# not asserted: in the closed-fd and 3.2 fallbacks a traced multiline
# argument still leaks continuation lines past the strip; that is the
# mark-and-strip boundary, not a seam regression. The test sources the real
# wrapper build and the real strip line from bin/shellm.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0 skipped=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
skip() { skipped=$((skipped+1)); printf 'skip %s\n' "$1"; }

# --- the real machinery, extracted verbatim ---------------------------------
# Boundary-checked so a drifted bin/shellm can never make this source
# arbitrary code: first line must open the assignment, last must close it.
sed -n '/^        wrapped_code="/,/^"$/p' "$REPO/bin/shellm" | sed 's/^        //' > "$WORK/wrapper.src"
wlines=()
while IFS= read -r w; do wlines+=("$w"); done < "$WORK/wrapper.src"
wlast=${#wlines[@]}
if [[ "$wlast" -lt 5 || "$wlast" -gt 15 \
      || "${wlines[0]}" != 'wrapped_code="'* || "${wlines[$((wlast-1))]}" != '"' ]]; then
    printf 'FAIL wrapper build extraction drifted (%s lines, first: %s); re-read run_agent_loop\n' \
        "$wlast" "${wlines[0]:-<empty>}" >&2
    exit 1
fi
strip_hits=$(grep -c '^        clean_output=' "$REPO/bin/shellm")
if [[ "$strip_hits" -ne 1 ]]; then
    printf 'FAIL strip line no longer unique (%s hits); re-read run_agent_loop\n' "$strip_hits" >&2
    exit 1
fi
strip_src=$(grep '^        clean_output=' "$REPO/bin/shellm" | sed 's/^        //')

# Execute a generated block the way the agent loop does: the real wrapper
# text, both streams merged into one capture. TRACE_FILE routes the fd 9
# gate; blank leaves it unset, the bash 3.2 shape on any bash.
run_block() {
    # shellcheck disable=SC2034  # code, final_path and trace_file are expanded into the sourced wrapper build
    local code="$1" final_path="$WORK/final" trace_file="${2:-}" merged="$WORK/merged"
    local wrapped_code=""
    [[ -n "$trace_file" ]] && : > "$trace_file" || true
    # shellcheck disable=SC1090
    source "$WORK/wrapper.src"
    bash -c "$wrapped_code" > "$merged" 2>&1
}

# The real storage strip, applied to the captured stream.
stored() {
    # shellcheck disable=SC2034  # output is read by $strip_src, eval'd below
    local output="" clean_output=""
    output=$(cat "$WORK/merged")
    eval "$strip_src"
    printf '%s' "$clean_output"
}

can_fd=0
if [[ "${BASH_VERSINFO[0]}" -gt 4 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -ge 1 ]]; }; then
    can_fd=1
fi

# --- seam: trace never shares the captured stream (bash 4.1+) ---------------
code_a='true "line1 alpha
line2 beta
line3 gamma"
printf "%s\n" "+ counted 42 files"'
run_block "$code_a" "$WORK/trace"
if [[ "$can_fd" -eq 1 ]]; then
    if grep -qx -- '+ counted 42 files' "$WORK/merged"; then
        ok "genuine plus prefixed output survives the seam"
    else
        bad "genuine plus prefixed output missing from the captured stream"
    fi
    if grep -q -- 'line2 beta' "$WORK/merged"; then
        bad "traced multiline argument reached the captured stream (continuation leak)"
    else
        ok "traced multiline argument stays out of the captured stream"
    fi
    if grep -q "^"$'\001' "$WORK/merged"; then
        bad "marked trace line reached the captured stream"
    else
        ok "no marked trace line reaches the captured stream"
    fi
    if grep -q -- 'line2 beta' "$WORK/trace"; then
        ok "trace stays visible to the operator in the trace file"
    else
        bad "trace file lost the traced multiline argument"
    fi
else
    skip "seam case (fd 9 gate needs bash 4.1+)"
fi

# --- glue: trace cannot join an unterminated output line mid-line ----------
code_g='printf "%s" "unterminated tail"
true "glue payload alpha
glue payload beta"'
run_block "$code_g" "$WORK/trace"
if [[ "$can_fd" -eq 1 ]]; then
    if grep -q -- 'glue payload' "$WORK/merged"; then
        bad "trace glued onto the unterminated output line in the captured stream"
    else
        ok "no trace glue on the unterminated output line"
    fi
else
    skip "glue case (fd 9 gate needs bash 4.1+)"
fi

# --- closure fallback: a block that closes fd 9 returns marked trace to stderr
code_b='exec 9>&- || true
true "line1 alpha
line2 beta"
printf "%s\n" "+ after closure"'
run_block "$code_b" "$WORK/trace"
if grep -qx -- '+ after closure' <(stored); then
    ok "genuine plus prefixed output survives the closed-fd fallback"
else
    bad "genuine plus prefixed output swallowed in the closed-fd fallback"
fi
if grep -q "^"$'\001' <(stored); then
    bad "marked trace line survived the storage strip in the closed-fd fallback"
else
    ok "marked trace lines dropped by the storage strip in the closed-fd fallback"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[[ $fail -eq 0 ]]
