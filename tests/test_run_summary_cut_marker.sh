#!/usr/bin/env bash
# tests/test_run_summary_cut_marker.sh — the run-summary combined-context cap is marked.
#
# Usage: tests/test_run_summary_cut_marker.sh
#
# generate_run_summary in bin/shellm builds the summary model's only view
# of a run's inputs from the CLI prompt, piped stdin and each -f file,
# capped at 20000 chars with no marker: the summary model read a capped run
# as whole. The cap stays (it bounds the summary call); every cut is now
# marked with the dropped count and a route to the full text. The CLI
# argument is recorded whole as the run's prompt step, files stay at their
# paths, and stdin is not stored anywhere past the summary call, so a fully
# cut input is named with its whole size rather than silently omitted. The
# summary system prompt tells the model what a marked line means.
#
# `llm` is stubbed (records every -M and -s payload, no network), same
# pattern as tests/test_var_secrets.sh. Local execution is pinned.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK="${SHELLM_TEST_WORK:-}"
if [[ -z "$WORK" ]]; then
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
else
    rm -rf "$WORK"; mkdir -p "$WORK"
fi

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub -----------------------------------------------------------------
mkdir -p "$WORK/script" "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
# Only the main loop passes --thinking; the background run-summary call does
# not. Record every -M and -s payload so the test sees what each call was fed.
prev=""
main_loop=0
for a in "$@"; do
    [[ "$a" == "--thinking" ]] && main_loop=1
    [[ "$prev" == "-M" ]] && printf '\n<PAYLOAD-M>\n%s\n</PAYLOAD-M>\n' "$a" >> "$LLM_CAPTURE"
    [[ "$prev" == "-s" ]] && printf '%s\n' "$a" >> "$LLM_CAPTURE_S"
    prev="$a"
done
if [[ "$main_loop" -ne 1 ]]; then printf '{}\n'; exit 0; fi
printf '```bash\nFINAL=done\n```\n'
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export LLM_CAPTURE="$WORK/calls"
export LLM_CAPTURE_S="$WORK/calls.s"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
# An inherited TRAJ_DIR / SHELLM_TRAJ_DIR (any run inside shellm) outranks
# HEADLONG_HOME in bin/shellm, so the stub runs would write into the
# caller's real trajectory (see tests/test_nested_traj_isolation.sh).
unset TRAJ_DIR TRAJ_ID SHELLM_TRAJ_DIR ROOT_TRAJ_ID
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

run_shellm() {
    : > "$LLM_CAPTURE"
    : > "$LLM_CAPTURE_S"
    rm -rf "$WORK/wd"; mkdir -p "$WORK/wd"
    local in="${STDIN_FILE:-/dev/null}"
    ( cd "$WORK/wd" && "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 1 "$@" ) \
        > "$WORK/out" 2> "$WORK/err" < "$in"
}

summary_line() { # $1: a token carried only by this arm's summary payload
    awk -v tok="$1" '
        /^<PAYLOAD-M>$/ { inblock=1; block=""; next }
        /^<\/PAYLOAD-M>$/ { inblock=0; if (index(block, tok) && index(block, "Analyze the context and goal")) last=block; next }
        inblock { block = block $0 "\n" }
        END { printf "%s", last }
    ' "$LLM_CAPTURE"
}

marked() { grep -qE '\(\+[0-9]+ (chars|bytes) more:' <<<"$1"; }

# ── Arm A: a prompt over the cap is cut and marked; the tail lives in the prompt step
HEAD_A="armA-head-$$"
TAIL_A="armA-tail-$$"
PA="$WORK/prompt-a.txt"
{ printf '%s ' "$HEAD_A"; head -c 20460 /dev/zero | tr '\0' x; printf '%s' "$TAIL_A"; } > "$PA"
PLEN=$(wc -c < "$PA" | tr -d ' ')   # ASCII fixture: chars and bytes agree
DROP_A=$((PLEN - 20000))
run_shellm --prompt-file "$PA"
SUMA=$(summary_line "$HEAD_A")
if [[ -n "$SUMA" ]]; then ok "arm A: the summary call is captured"; else bad "arm A: the summary call is captured" "no summary payload recorded"; fi
MARK_A="(+$DROP_A chars more: full text in the prompt step of this run)"
if grep -qF "$MARK_A" <<<"$SUMA"; then ok "arm A: the prompt cut is marked with the dropped count and route"; else bad "arm A: the prompt cut is marked with the dropped count and route" "wanted $MARK_A"; fi
if [[ "$SUMA" != *"$TAIL_A"* ]]; then ok "arm A: the beyond-cap tail is not fed as whole text"; else bad "arm A: the beyond-cap tail is not fed as whole text"; fi
if grep -rqF "$TAIL_A" "$HEADLONG_HOME/trajectories"; then ok "arm A: the full prompt is still recorded whole as the run's prompt step"; else bad "arm A: the full prompt is still recorded whole as the run's prompt step"; fi
TRAJ_A=$(grep -rlF "$TAIL_A" "$HEADLONG_HOME/trajectories" --include=trajectory.jsonl | head -1)
if [[ -n "$TRAJ_A" ]] && grep -q '"type":"run-summary"' "$TRAJ_A"; then ok "arm A: a run-summary row landed for the run"; else bad "arm A: a run-summary row landed for the run"; fi
if grep -qF 'marks a cut input' "$LLM_CAPTURE_S"; then ok "arm A: the summary prompt says what a marked line means"; else bad "arm A: the summary prompt says what a marked line means"; fi

# ── Arm B: stdin over the cap is cut and marked; stdin is stored nowhere
HEAD_B="armB-head-$$"
TAIL_B="armB-tail-$$"
PB="armB small prompt"
SB="$WORK/stdin-b.txt"
{ printf '%s' "$HEAD_B"; head -c 20970 /dev/zero | tr '\0' y; printf '%s' "$TAIL_B"; } > "$SB"
SLEN=$(wc -c < "$SB" | tr -d ' ')
PREFIX_B="CLI argument: $PB"
KEPT_B=$((20000 - ${#PREFIX_B}))
DROP_B=$((SLEN - KEPT_B))
printf '%s' "$PB" > "$WORK/prompt-b.txt"
STDIN_FILE="$SB" run_shellm --prompt-file "$WORK/prompt-b.txt"
SUMB=$(summary_line "$HEAD_B")
MARK_B="(+$DROP_B chars more: stdin is not stored anywhere)"
if grep -qF "$MARK_B" <<<"$SUMB"; then ok "arm B: the stdin cut is marked with the exact dropped count"; else bad "arm B: the stdin cut is marked with the exact dropped count" "wanted $MARK_B"; fi
if [[ "$SUMB" != *"$TAIL_B"* ]]; then ok "arm B: the beyond-cap stdin tail is not fed as whole text"; else bad "arm B: the beyond-cap stdin tail is not fed as whole text"; fi

# ── Arm C: an over-cap prompt makes stdin and file full-cut markers, not silence
HEAD_C="armC-head-$$"
STDTOK_C="armC-std-$$"
FILETOK_C="armC-file-$$"
PC="$WORK/prompt-c.txt"
{ printf '%s ' "$HEAD_C"; head -c 20470 /dev/zero | tr '\0' z; } > "$PC"
SC="$WORK/stdin-c.txt"; printf '%s' "$STDTOK_C filler text for arm C stdin" > "$SC"
FC="$WORK/file-c.txt"; printf '%s' "$FILETOK_C filler text for arm C file" > "$FC"
STDIN_FILE="$SC" run_shellm --prompt-file "$PC" -f "$FC"
SUMC=$(summary_line "$HEAD_C")
SLEN_C=$(wc -c < "$SC" | tr -d ' ')
FLEN_C=$(wc -c < "$FC" | tr -d ' ')
if grep -qF "(+$SLEN_C chars more: stdin is not stored anywhere)" <<<"$SUMC"; then ok "arm C: a fully cut stdin is named with its whole length"; else bad "arm C: a fully cut stdin is named with its whole length" "wanted +$SLEN_C chars"; fi
if grep -qF "(+$FLEN_C bytes more: full file at $FC)" <<<"$SUMC"; then ok "arm C: a fully cut file is named with its whole length and path"; else bad "arm C: a fully cut file is named with its whole length and path" "wanted +$FLEN_C bytes at $FC"; fi
if [[ "$SUMC" != *"$STDTOK_C"* && "$SUMC" != *"$FILETOK_C"* ]]; then ok "arm C: the cut stdin and file text are not fed as whole"; else bad "arm C: the cut stdin and file text are not fed as whole"; fi
if grep -qF "(+$(( $(wc -c < "$PC" | tr -d ' ') - 20000 )) chars more: full text in the prompt step of this run)" <<<"$SUMC"; then ok "arm C: the over-cap prompt marker is present beside the full-cut markers"; else bad "arm C: the over-cap prompt marker is present beside the full-cut markers"; fi

# ── Arm D: a partially cut file keeps its route to the real path
HEAD_D="armD-head-$$"
TAIL_D="armD-tail-$$"
PD="$HEAD_D small prompt"
SD="armD small stdin"
FD="$WORK/file-d.txt"
{ head -c 20460 /dev/zero | tr '\0' w; printf '%s' "$TAIL_D"; } > "$FD"
FLEN_D=$(wc -c < "$FD" | tr -d ' ')
CB_D="CLI argument: $PD"$'\n\nstdin:\n'"$SD"
AVAIL_D=$((20000 - ${#CB_D}))
DROP_D=$((FLEN_D - AVAIL_D))
printf '%s' "$PD" > "$WORK/prompt-d.txt"
printf '%s' "$SD" > "$WORK/stdin-d.txt"
STDIN_FILE="$WORK/stdin-d.txt" run_shellm --prompt-file "$WORK/prompt-d.txt" -f "$FD"
SUMD=$(summary_line "$HEAD_D")
if grep -qF "(+$DROP_D bytes more: full file at $FD)" <<<"$SUMD"; then ok "arm D: the partially cut file is marked with the exact dropped count and path"; else bad "arm D: the partially cut file is marked with the exact dropped count and path" "wanted +$DROP_D bytes at $FD"; fi
if [[ "$SUMD" != *"$TAIL_D"* ]]; then ok "arm D: the beyond-cap file tail is not fed as whole text"; else bad "arm D: the beyond-cap file tail is not fed as whole text"; fi

# ── Arm E: under the cap, nothing is marked and everything is whole
STDTOK_E="armE-std-$$"
FILETOK_E="armE-file-$$"
PE="$WORK/prompt-e.txt"; printf 'armE prompt %s' "$$" > "$PE"
SE="$WORK/stdin-e.txt"; printf '%s' "$STDTOK_E arm E stdin content" > "$SE"
FE="$WORK/file-e.txt"; printf '%s' "$FILETOK_E arm E file content" > "$FE"
STDIN_FILE="$SE" run_shellm --prompt-file "$PE" -f "$FE"
SUME=$(summary_line "armE prompt")
if [[ "$SUME" == *"armE prompt"* && "$SUME" == *"$STDTOK_E"* && "$SUME" == *"$FILETOK_E"* ]]; then ok "arm E: prompt, stdin and file all reach the summary whole"; else bad "arm E: prompt, stdin and file all reach the summary whole"; fi
if ! marked "$SUME"; then ok "arm E: an under-cap run renders no markers"; else bad "arm E: an under-cap run renders no markers"; fi

# ── Arm F: a prompt exactly at the cap renders no marker
HEAD_F="armF-head-$$"
TAIL_F="armF-tail-$$"
PF="$WORK/prompt-f.txt"
PAD=$((20000 - ${#HEAD_F} - ${#TAIL_F} - 1))
{ printf '%s ' "$HEAD_F"; head -c "$PAD" /dev/zero | tr '\0' q; printf '%s' "$TAIL_F"; } > "$PF"
PFLEN=$(wc -c < "$PF" | tr -d ' ')
if [[ "$PFLEN" -eq 20000 ]]; then
    run_shellm --prompt-file "$PF"
    SUMF=$(summary_line "$HEAD_F")
    if [[ "$SUMF" == *"$TAIL_F"* ]]; then ok "arm F: a prompt exactly at the cap reaches the summary whole"; else bad "arm F: a prompt exactly at the cap reaches the summary whole"; fi
    if ! marked "$SUMF"; then ok "arm F: a prompt exactly at the cap renders no marker"; else bad "arm F: a prompt exactly at the cap renders no marker"; fi
else
    bad "arm F: a prompt exactly at the cap renders no marker" "fixture is $PFLEN chars, test bug"
fi

printf 'run-summary-cut-marker: %s checks, %s failures\n' "$((pass + fail))" "$fail"
[[ $fail -eq 0 ]]
