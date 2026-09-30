#!/usr/bin/env bash
# tests/test_exec_status_capture.sh — the wrapper captures the model's own
# exit status, not the status of its own bookkeeping lines.
#
# Usage: tests/test_exec_status_capture.sh
#
# The wrapper that runs generated code is built in run_loop and executed
# verbatim, so the wrapped text is the product. This test lifts the real
# wrapper construction out of bin/shellm, substitutes a probe for the
# model's code exactly as production does ($code and $final_path at build
# time), and runs the result the way _supervise_exec runs small code:
# bash -e -c with stdin from /dev/null.
#
# On main the capture line sits one line after `set +x`, so it reads the
# status of set +x (always zero). Generated code that ends in `set +e` and a
# failing command therefore reports failure as success.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# Lift the wrapper block: from the unique comment through the closing quote
# after `exit $__shellm_rc`. The awk bracket expression keeps the dollar a
# literal, not an anchor.
wrapper_src=$(awk '
    /# Build wrapped code that captures/ {on=1}
    on {print}
    on && /exit \\[$]__shellm_rc/ {getline nxt; print nxt; exit}
' "$REPO/bin/shellm")
if [[ "$wrapper_src" != *'__shellm_rc=\$?'* ]]; then
    bad "wrapper block extracted from bin/shellm" "capture line not found"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
ok "wrapper block extracted from bin/shellm"

run_wrapped() {
    # Build and run exactly as production does: same locals in scope, same
    # bash -e -c path, stdin /dev/null.
    local code="$1" final_path="$2"
    # shellcheck disable=SC1078,SC1079  # one long double-quoted string, built across lines on purpose
    eval "$wrapper_src"
    bash -e -c "$wrapped_code" </dev/null >/dev/null 2>&1
}

# --- cases ----------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. code ending set +e then failing command: the shape that loses on main
if ! run_wrapped 'set +e
false' "$tmp/f1"; then ok "set +e then false reports failure"; else bad "set +e then false reports failure" "exit 0"; fi

# 2. semantics control: the capture is the model's LAST command, so an early
#    failure followed by success exits zero, exactly as the code would standalone
if run_wrapped 'set +e
false
true' "$tmp/f2"; then ok "set +e, false, true: last command status wins"; else bad "set +e, false, true: last command status wins" "exit nonzero"; fi

# 3. failing pipeline under set +e (the wrapper sets no pipefail)
if ! run_wrapped 'set +e
echo hi | grep -q zz' "$tmp/f3"; then ok "set +e pipeline miss reports failure"; else bad "set +e pipeline miss reports failure" "exit 0"; fi

# 4. command not found under set +e
if ! run_wrapped 'set +e
no_such_command_xyz' "$tmp/f4"; then ok "command not found reports failure"; else bad "command not found reports failure" "exit 0"; fi

# 5. failed arithmetic expansion under set +e
if ! run_wrapped 'set +e
echo $((1/0))' "$tmp/f5"; then ok "arithmetic failure reports failure"; else bad "arithmetic failure reports failure" "exit 0"; fi

# 6. failing function return under set +e
if ! run_wrapped 'set +e
f() { return 3; }
f' "$tmp/f6"; then ok "failing return reports failure"; else bad "failing return reports failure" "exit 0"; fi

# 7. plain failing command, no set +e: errexit saved this on main by accident
if ! run_wrapped 'false' "$tmp/f7"; then ok "plain false under errexit reports failure"; else bad "plain false under errexit reports failure" "exit 0"; fi

# 8. control: succeeding code still exits zero
if run_wrapped 'true' "$tmp/f8"; then ok "plain true exits zero"; else bad "plain true exits zero" "exit nonzero"; fi

# 9. control: set +e ending on success still exits zero
if run_wrapped 'set +e
true' "$tmp/f9"; then ok "set +e true exits zero"; else bad "set +e true exits zero" "exit nonzero"; fi

# 10. FINAL is still captured when the code fails (the write runs before exit)
rm -f "$tmp/f10"
run_wrapped 'set +e
false
FINAL=done' "$tmp/f10"
if [[ -f "$tmp/f10" && "$(cat "$tmp/f10")" == "done" ]]; then ok "FINAL captured despite failing code"; else bad "FINAL captured despite failing code" "missing or wrong content"; fi

# 11. FINAL_FILE still captured when the code fails
printf 'file-done' > "$tmp/src11"
rm -f "$tmp/f11"
run_wrapped "set +e
false
FINAL_FILE=$tmp/src11" "$tmp/f11"
if [[ -f "$tmp/f11" && "$(cat "$tmp/f11")" == "file-done" ]]; then ok "FINAL_FILE captured despite failing code"; else bad "FINAL_FILE captured despite failing code" "missing or wrong content"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
