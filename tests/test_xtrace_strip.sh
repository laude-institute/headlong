#!/usr/bin/env bash
# tests/test_xtrace_strip.sh — regression: genuine plus-prefixed output must
# survive the storage strip. The agent loop wraps every generated block in
# `set -x`, so xtrace trace lines and genuine program output share the one
# captured stream; the storage strip then drops every line shaped like a
# trace line, so genuine output that begins with a plus prefix vanishes from
# the stored shell-output record with no marker. The test sources the real
# wrapper build and the real strip line from bin/shellm, so it stays agnostic
# to the fix route (dropping set -x together with the strip, or routing the
# trace to its own fd), and it stays red if either half is fixed alone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# --- the real machinery, extracted verbatim ---------------------------------
# The wrapper build is one multi-line assignment; pull exactly that range.
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
# text, both streams merged into one capture, then the real storage strip.
run_block() {
    # shellcheck disable=SC2034  # code, final_path and trace_file are expanded into the sourced wrapper build
    local code="$1" final_path="$WORK/final" trace_file="${2:-}" merged="$WORK/merged"
    local wrapped_code="" output="" clean_output=""
    [[ -n "$trace_file" ]] && : > "$trace_file" || true
    # shellcheck disable=SC1090
    source "$WORK/wrapper.src"
    bash -c "$wrapped_code" > "$merged" 2>&1
    # shellcheck disable=SC2034  # output is read by $strip_src, eval'd below
    output=$(cat "$merged")
    eval "$strip_src"
    printf '%s' "$clean_output"
}

# --- genuine plus-prefixed output must survive storage ----------------------
code_a=$(cat <<'CODE'
p="+"
printf '%s\n' "${p} counted 42 files"
printf '%s\n' "plain marker line"
CODE
)
res_a=$(run_block "$code_a")
if grep -qx -- '+ counted 42 files' <<<"$res_a"; then
    ok "single plus prefixed output line survives storage"
else
    bad "single plus prefixed output line survives storage (swallowed by the strip)"
fi
if grep -qx -- 'plain marker line' <<<"$res_a"; then
    ok "plain output line survives storage"
else
    bad "plain output line survives storage"
fi

code_b=$(cat <<'CODE'
pp="++"
printf '%s\n' "${pp} double plus content"
CODE
)
res_b=$(run_block "$code_b")
if grep -qx -- '++ double plus content' <<<"$res_b"; then
    ok "double plus prefixed output line survives storage"
else
    bad "double plus prefixed output line survives storage (swallowed by the strip)"
fi

# --- control: trace residue must not reach storage --------------------------
res_c=$(run_block 'true')
if [[ -z "$res_c" ]]; then
    ok "trace residue does not reach storage"
else
    bad "trace residue does not reach storage: [$res_c]"
fi

# --- fallback: with the trace fd unset (bash 3.2, or a blank trace path)
# marked trace reaches the captured stream; the strip must drop it and
# keep genuine plus-prefixed output.
res_d=$(run_block 'printf "%s\n" "+ no trace file"' "")
if grep -qx -- '+ no trace file' <<<"$res_d"; then
    ok "plus prefixed output survives the no-fd fallback"
else
    bad "plus prefixed output swallowed in the no-fd fallback"
fi
if grep -q "^"$'\001' <<<"$res_d"; then
    bad "marked trace line survived the strip in the no-fd fallback"
else
    ok "marked trace lines dropped by the strip in the no-fd fallback"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
