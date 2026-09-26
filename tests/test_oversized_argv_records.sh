#!/usr/bin/env bash
# tests/test_oversized_argv_records.sh — model-sized strings never ride argv.
#
# Usage: tests/test_oversized_argv_records.sh
#
# Linux caps a single argv string at 128 KiB (MAX_ARG_STRLEN). Three strings
# that can be far larger used to travel through one anyway: the generated
# code block (`bash -c "$code"` in _supervise_exec) and the recorded
# reasoning and final answers (`jq -n --arg ...`). A code block just over
# the cap killed the exec itself: rc=126 "Argument list too long", the step
# never ran, and a whole wake died with nothing durable (live 2026-09-26
# 09:58Z). The fix keeps `bash -c` for small code, runs big code from a
# mode-600 script file, and records reasoning/final through jq --rawfile,
# the pattern the prompt and shell-output records already use.
#
# The stub `traj` saves both its stdin (the record json) and every argv
# string it is handed, so a regression to argv fails loudly, and record
# contents are checked with jq rather than string matching.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SHELLM="$REPO/bin/shellm"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export WORK

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# ── stubs ──────────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin" "$WORK/traj"
cat > "$WORK/bin/traj" <<'STUB'
#!/usr/bin/env bash
cat >> "$STUB_STDIN"
printf 'ARG:%s\0' "$@" >> "$STUB_ARGV"
exit 0
STUB
chmod +x "$WORK/bin/traj"
export STUB_STDIN="$WORK/traj_stdin" STUB_ARGV="$WORK/traj_argv"
export PATH="$WORK/bin:$PATH"

check_record() {  # label record-type field expected
    local label="$1" rectype="$2" filter="$3" want="$4" got
    got=$(jq -sr --arg t "$rectype" 'map(select(.type==$t))[0] | ('"$filter"')' "$STUB_STDIN" 2>/dev/null) || got=""
    if [[ "$got" == "$want" ]]; then ok "$label"; else bad "$label" "jq '$filter' gave '$got', wanted '$want'"; fi
    local a oversize=()
    while IFS= read -r -d '' a; do
        [[ ${#a} -gt 131071 ]] && oversize+=("${#a} bytes")
    done < "$STUB_ARGV"
    if [[ ${#oversize[@]} -eq 0 ]]; then ok "$label: no oversized argv"; else bad "$label: no oversized argv" "${oversize[*]}"; fi
}

# ── case 1: an oversized code block executes instead of dying rc=126 ──────
sed -n '/^_supervise_exec()/,/^}/p' "$SHELLM" > "$WORK/sup.sh"
{
    printf '# '
    head -c 200000 /dev/zero | tr '\0' x
    printf '\necho ok > "$WORK/r2"\n'
    printf 'v=$(head -c 200000 /dev/zero | tr "\\0" x)\nprintf "%%s\\\\n" "${#v}" > "$WORK/r3"\n'
} > "$WORK/big_code.sh"
cat > "$WORK/driver_sup.sh" <<'DRV'
set -e
source "$WORK/sup.sh"
code=$(cat "$WORK/big_code.sh")
rc=0
_supervise_exec "$code" "" || rc=$?
echo "$rc" > "$WORK/r1rc"
DRV
rm -f "$WORK/r2" "$WORK/r3" "$WORK/r1rc"
bash "$WORK/driver_sup.sh" 2>"$WORK/sup_err" || true
[[ -f "$WORK/r2" ]] && ok "oversized code block executed (not rc=126)" || bad "oversized code block executed (not rc=126)" "$(head -c 200 "$WORK/sup_err")"
[[ "$(cat "$WORK/r3" 2>/dev/null)" == 200000 ]] && ok "oversized code body intact" || bad "oversized code body intact" "r3=$(cat "$WORK/r3" 2>/dev/null)"
[[ "$(cat "$WORK/r1rc" 2>/dev/null)" == 0 ]] && ok "supervisor rc=0 on oversized code" || bad "supervisor rc=0 on oversized code" "rc=$(cat "$WORK/r1rc" 2>/dev/null)"

# small code keeps the argv path and still works
cat > "$WORK/driver_small.sh" <<'DRV'
set -e
source "$WORK/sup.sh"
_supervise_exec 'echo small > "$WORK/r4"' ""
DRV
rm -f "$WORK/r4"
bash "$WORK/driver_small.sh" 2>/dev/null || true
[[ "$(cat "$WORK/r4" 2>/dev/null)" == small ]] && ok "small code path unchanged" || bad "small code path unchanged" "r4=$(cat "$WORK/r4" 2>/dev/null)"

# ── case 2: reasoning record with 200KB thought and cmd goes via --rawfile ─
ra=$(grep -n '_reasoning_thought_tmp=$(mktemp)' "$SHELLM" | head -1 | cut -d: -f1)
rend=$(grep -n 'Record shell-output step' "$SHELLM" | head -1 | cut -d: -f1)
sed -n "$((ra-1)),$((rend-1))p" "$SHELLM" > "$WORK/reason_block.txt"
cat > "$WORK/driver_reason.sh" <<'DRV'
set -e
redact_sensitive() { :; }
_run_step_id=t1; _llm_s=1; _usage_extra='{}'
_run_traj_dir="$WORK/traj"; _run_traj_id=tr1
reasoning=$(cat "$WORK/thought.txt")
code=$(cat "$WORK/cmd.txt")
eval "_rec() {
$(cat "$WORK/reason_block.txt")
}"
_rec
DRV
head -c 200000 /dev/zero | tr '\0' y > "$WORK/thought.txt"
head -c 200000 /dev/zero | tr '\0' c > "$WORK/cmd.txt"
: > "$STUB_STDIN"; : > "$STUB_ARGV"
bash "$WORK/driver_reason.sh" 2>"$WORK/reason_err" || true
check_record "oversized reasoning recorded via rawfile" reasoning '.type' "reasoning"
check_record "reasoning thought intact" reasoning '(.thought | length)' 200000
check_record "reasoning cmd intact" reasoning '(.cmd | length)' 200000

# ── case 3: 200KB final answer goes via --rawfile ──────────────────────────
fstart=$(grep -n 'Check for final answer' "$SHELLM" | head -1 | cut -d: -f1)
rline=$(awk -v s="$fstart" 'NR>s && /return 0/ {print NR; exit}' "$SHELLM")
fend=$(awk -v s="$rline" 'NR>=s && /^        fi$/ {print NR; exit}' "$SHELLM")
sed -n "${fstart},${fend}p" "$SHELLM" > "$WORK/final_block.txt"
cat > "$WORK/driver_final.sh" <<'DRV'
set -e
redact_sensitive() { :; }
progress() { :; }
progress_dim() { :; }
QUIET=1
_run_step_id=t2
_run_traj_dir="$WORK/traj"; _run_traj_id=tr2
final_path="$WORK/final"
eval "_fin() {
$(cat "$WORK/final_block.txt")
}"
_fin
DRV
head -c 200000 /dev/zero | tr '\0' z > "$WORK/final"
: > "$STUB_STDIN"; : > "$STUB_ARGV"
bash "$WORK/driver_final.sh" 2>"$WORK/final_err" || true
check_record "oversized final recorded via rawfile" final '.type' "final"
check_record "final content intact" final '(.content | length)' 200000

r=$((pass+fail)); printf '\n%d checks: %d ok, %d failed\n' "$r" "$pass" "$fail"
[[ $fail -eq 0 ]]
