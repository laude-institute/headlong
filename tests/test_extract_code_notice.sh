#!/usr/bin/env bash
# tests/test_extract_code_notice.sh — bin/shellm extract_code behavior, and the
# stderr notice it prepends when a reply has no bash code block.
#
# Usage: tests/test_extract_code_notice.sh
#
# When a model reply has no ```bash block, shellm runs the whole reply as a
# shell command (the no-fence fallback). That is almost always the model ending
# its turn with a plain sentence, which fails "command not found" and, on a
# weaker model, repeats until the run is killed as a stall (Nemotron on idle
# wakes, 2026-09-05). extract_code now prepends a notice — captured on stderr
# and shown back to the model next turn — that says the reply ran as a command
# and how to end a run (FINAL= inside a bash block). This test loads extract_code
# out of bin/shellm and checks the notice fires only for bare prose with real
# content.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# Load just extract_code from bin/shellm. Source from a temp file, not
# `source <(...)`: the CI macOS bash 3.2 binary has no process substitution.
FN=$(mktemp)
trap 'rm -f "$FN"' EXIT
sed -n '/^normalize_toolcall_markup() {/,/^}/p' "$REPO/bin/shellm" > "$FN"
sed -n '/^extract_code() {/,/^}/p' "$REPO/bin/shellm" >> "$FN"
# shellcheck disable=SC1090
source "$FN"

NOTICE='shellm: your reply had no'   # start of the prepended notice line

# Bare prose: notice prepended, and the prose is still present as code.
out=$(extract_code "Idle — nothing to do now.")
grep -q "$NOTICE" <<<"$out" && ok "bare prose gets the no-fence notice" || bad "bare prose notice" "$out"
grep -q 'Idle — nothing to do now\.' <<<"$out" && ok "the prose is still passed through as code" || bad "prose passthrough"
grep -q 'FINAL=' <<<"$out" && ok "the notice tells the model how to end a run (FINAL=)" || bad "notice mentions FINAL="

# A fenced block: no notice, just the code.
out=$(extract_code "Let me look.
\`\`\`bash
ls -la
\`\`\`")
grep -q "$NOTICE" <<<"$out" && bad "a fenced reply must not get the notice" || ok "a fenced reply gets no notice"
[[ "$(printf '%s' "$out")" == "ls -la" ]] && ok "a fenced reply extracts just its code" || bad "fenced extract" "$out"

# A clean FINAL= block: no notice.
out=$(extract_code "\`\`\`bash
FINAL=\"done\"
\`\`\`")
grep -q "$NOTICE" <<<"$out" && bad "a FINAL= block must not get the notice" || ok "a FINAL= block gets no notice"

# Whitespace-only reply: no notice (empty code is treated as a final upstream).
out=$(extract_code "   ")
grep -q "$NOTICE" <<<"$out" && bad "a blank reply must not get the notice" || ok "a blank reply gets no notice"

# A fence appended to the end of a prose line (grok style) still counts as fenced.
out=$(extract_code "do it now.\`\`\`bash
echo hi
\`\`\`")
grep -q "$NOTICE" <<<"$out" && bad "an end-of-line fence must not get the notice" || ok "an end-of-line fence gets no notice"

# --- Qwen tool-call markup is lifted into a fence and runs, with a notice ------
# Four shapes seen on Custos 2026-09-09: canonical <tool_call><function=bash>…
# </function></tool_call>; the hybrid …</bash>; a bare <tool_call> wrapper; and
# <parameter=command> inside <function=bash>. A real fence always wins.
for shape in canonical hybrid bare parameter; do
    case "$shape" in
        canonical) resp=$'Let me check.\n<tool_call>\n<function=bash>\necho lifted-canonical\n</function>\n</tool_call>' ;;
        hybrid)    resp=$'<tool_call>\n<function=bash>\necho lifted-hybrid\n</bash>\n\n</bash>' ;;
        bare)      resp=$'<tool_call>\necho lifted-bare\nFINAL="done"' ;;
        parameter) resp=$'<tool_call>\n<function=bash>\n<parameter=command>\necho lifted-parameter\n</parameter>\n</function>\n</tool_call>' ;;
    esac
    out=$(extract_code "$resp")
    ran=$(bash -c "$out" 2>/tmp/notice.$$)
    if [[ "$ran" == "lifted-$shape"* ]] && grep -q 'used <tool_call>/<function=bash> markup' /tmp/notice.$$; then
        ok "tool-call markup ($shape) is lifted, runs, and carries the notice"
    else
        bad "tool-call markup ($shape) is lifted, runs, and carries the notice" "ran=$ran notice=$(cat /tmp/notice.$$ | head -c 120)"
    fi
    rm -f /tmp/notice.$$
done
out=$(extract_code $'<tool_call> mentioned in prose\n```bash\necho fence-wins\n```')
if [[ "$(bash -c "$out" 2>/dev/null)" == "fence-wins" ]] && [[ "$out" != *"used <tool_call>"* ]]; then
    ok "a real fence wins over tool-call words in prose"
else
    bad "a real fence wins over tool-call words in prose" "$out"
fi


echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
