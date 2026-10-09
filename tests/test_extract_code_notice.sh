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
WORK=$(mktemp -d)
FN="$WORK/functions"
trap 'rm -rf "$WORK"' EXIT
for fn in script_parses strip_markup_suffix normalize_toolcall_markup; do
    sed -n "/^$fn() {/,/^}/p" "$REPO/bin/shellm"
done > "$FN"
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
    ran=$(bash -c "$out" 2>"$WORK/notice")
    if [[ "$ran" == "lifted-$shape"* ]] && grep -q 'used tool-call markup' "$WORK/notice"; then
        ok "tool-call markup ($shape) is lifted, runs, and carries the notice"
    else
        bad "tool-call markup ($shape) is lifted, runs, and carries the notice" "ran=$ran notice=$(cat "$WORK/notice" | head -c 120)"
    fi
    rm -f "$WORK/notice"
done
# MiMo shapes seen on Audel 2026-09-22 to 09-25: the tags inline on the first
# and last code lines, other parameter names, a trailing one-line parameter,
# and a prose sentence (apostrophes, backticks) before the markup.
for shape in inline cmd_timeout prose_prefix prose_lines block; do
    case "$shape" in
        inline)       resp=$'<tool_call><function=bash><parameter=command>echo lifted-inline\necho second</parameter></function></tool_call>' ;;
        cmd_timeout)  resp=$'<tool_call><function=bash><parameter=cmd>echo lifted-cmd_timeout</parameter>\n<parameter=timeout>30</parameter>\n</function></tool_call>' ;;
        prose_prefix) resp=$'Let me look at the evidence first.<tool_call><function=bash><parameter=command>echo lifted-prose_prefix\n</parameter></function></tool_call>' ;;
        prose_lines)  resp=$'I\'ll check the `mem add` syntax first.\n\nThat\'s the plan.<tool_call><function=bash><parameter=command>echo lifted-prose_lines</parameter></function></tool_call>' ;;
        block)        resp=$'<tool_call>\n<function=bash>\n<parameter=block>echo lifted-block\n</parameter>\n</function>\n</tool_call>' ;;
    esac
    out=$(extract_code "$resp")
    ran=$(bash -c "$out" 2>"$WORK/notice")
    if [[ "$ran" == "lifted-$shape"* ]] && grep -q 'used tool-call markup' "$WORK/notice"; then
        ok "MiMo markup ($shape) is lifted, runs, and carries the notice"
    else
        bad "MiMo markup ($shape) is lifted, runs, and carries the notice" "ran=$ran out=$(head -c 160 <<<"$out")"
    fi
    rm -f "$WORK/notice"
done
# A stray fence glued to the markup ("```<tool_call>…" closed by a lone ```).
resp=$'```<tool_call><function=bash><parameter=command>echo lifted-glued\n</parameter></function></tool_call>\n```'
ran=$(bash -c "$(extract_code "$resp")" 2>/dev/null)
[[ "$ran" == "lifted-glued" ]] && ok "a stray fence glued to the markup is lifted" || bad "a stray fence glued to the markup is lifted" "ran=$ran"
# A real fence whose code ends in MiMo's closing tags: the suffix is stripped,
# the script runs, and the model is told about the markup.
for shape in inline_suffix tag_lines; do
    case "$shape" in
        inline_suffix) resp=$'Checking.\n```bash\nfor x in a; do\n  echo fenced-$x\ndone</parameter></function></tool_call>\n```' ;;
        tag_lines)     resp=$'```bash\necho fenced-a\n</parameter>\n</function>\n</tool_call>\n```' ;;
    esac
    out=$(extract_code "$resp")
    ran=$(bash -c "$out" 2>"$WORK/notice")
    if [[ "$ran" == "fenced-a" ]] && grep -q 'used tool-call markup' "$WORK/notice"; then
        ok "fenced code ending in closing tags ($shape) is repaired and runs"
    else
        bad "fenced code ending in closing tags ($shape) is repaired and runs" "ran=$ran"
    fi
    rm -f "$WORK/notice"
done
# A fenced script that is valid as written keeps a trailing literal tag.
resp=$'```bash\ncat <<\'EOF\'\n</tool_call>\nEOF\n```'
out=$(extract_code "$resp")
[[ "$(bash -c "$out" 2>/dev/null)" == "</tool_call>" && "$out" != *"used tool-call markup"* ]] &&
    ok "a valid fenced script keeps its literal closing tag" || bad "a valid fenced script keeps its literal closing tag" "$out"
# A prefix that is shell code, or an open quote before the markup, is data.
for shape in shell_prefix backslash_prefix open_quote; do
    case "$shape" in
        shell_prefix) resp=$'x=1; echo done.<tool_call><function=bash><parameter=command>echo DATA\n</parameter></function></tool_call>' ;;
        backslash_prefix) resp=$'printf a\\\\b.<tool_call><function=bash><parameter=command>echo DATA\n</parameter></function></tool_call>' ;;
        open_quote)   resp=$'echo \'intro\n<tool_call>\necho DATA\n</tool_call>\'' ;;
    esac
    out=$(normalize_toolcall_markup "$resp"); rc=$?
    if [[ "$rc" -eq 1 && "$out" == "$resp" ]]; then
        ok "inline markup after shell code ($shape) is left unchanged"
    else
        bad "inline markup after shell code ($shape) is left unchanged" "rc=$rc"
    fi
done
out=$(extract_code $'<tool_call> mentioned in prose\n```bash\necho fence-wins\n```')
if [[ "$(bash -c "$out" 2>/dev/null)" == "fence-wins" ]] && [[ "$out" != *"used tool-call markup"* ]]; then
    ok "a real fence wins over tool-call words in prose"
else
    bad "a real fence wins over tool-call words in prose" "$out"
fi


# --- Literal tags must stay data, with and without an outer wrapper ---------
# Compare complete output, including a command after the literal. An inner
# echo being executed instead of printed must fail the comparison.
for quoting in heredoc single double; do
    case "$quoting" in
        heredoc) script=$(cat <<'SCRIPT'
cat <<'DATA'
<tool_call>
<function=bash>
<parameter=command>
<bash>
echo DATA_ONLY
</bash>
</parameter>
</function>
</tool_call>
DATA
echo AFTER
SCRIPT
) ;;
        single) script=$(cat <<'SCRIPT'
printf '%s\n' '<tool_call>
echo DATA_ONLY
</tool_call>'
echo AFTER
SCRIPT
) ;;
        double) script=$(cat <<'SCRIPT'
printf '%s\n' "<tool_call>
echo DATA_ONLY
</tool_call>"
echo AFTER
SCRIPT
) ;;
    esac
    expected=$(printf '%s\n' "$script" | bash)
    out=$(extract_code "$script")
    ran=$(printf '%s\n' "$out" | bash 2>"$WORK/notice")
    if [[ "$ran" == "$expected" && "$out" != *"used tool-call markup"* ]]; then
        ok "unfenced $quoting preserves literal tags and the trailing command"
    else
        bad "unfenced $quoting preserves literal tags and the trailing command" "$ran"
    fi
    resp=$'<tool_call>\n<function=bash>\n'"$script"$'\n</function>\n</tool_call>'
    out=$(extract_code "$resp")
    ran=$(printf '%s\n' "$out" | bash 2>"$WORK/notice")
    if [[ "$ran" == "$expected" && "$out" == *"used tool-call markup"* ]]; then
        ok "wrapped $quoting preserves literal tags and the trailing command"
    else
        bad "wrapped $quoting preserves literal tags and the trailing command" "$ran"
    fi
done

# Ambiguous or incomplete scripts must be returned unchanged. bash -n alone
# is insufficient: an unterminated heredoc warns but exits successfully.
for shape in quote heredoc tag_delimiter preamble unknown_tool; do
    case "$shape" in
        quote) resp=$'<tool_call>\nprintf "%s\\n" "unfinished\n</tool_call>' ;;
        heredoc) resp=$'<tool_call>\ncat <<EOF\nunfinished\n</tool_call>' ;;
        tag_delimiter) resp=$(cat <<'SCRIPT'
<tool_call>
cat <<'</tool_call>'
literal body
</tool_call>
</tool_call>
SCRIPT
) ;;
        preamble) resp=$'cat <<EOF\n<tool_call>\necho DATA_ONLY\n</tool_call>' ;;
        unknown_tool) resp=$'<tool_call>\n<function=python>\nprint("hello")\n</function>\n</tool_call>' ;;
    esac
    out=$(normalize_toolcall_markup "$resp"); rc=$?
    if [[ "$rc" -eq 1 && "$out" == "$resp" ]]; then
        ok "ambiguous markup ($shape) is left unchanged"
    else
        bad "ambiguous markup ($shape) is left unchanged" "rc=$rc"
    fi
done

# Several calls in one reply: only the first runs, as with fenced blocks, and
# the model is told the rest was dropped. A cut that lands inside a heredoc
# does not parse, so that reply falls back to lifting the whole body.
for shape in extra_call mimo_two mimo_sameline; do
    case "$shape" in
        extra_call) resp=$'<tool_call>\necho first\n</tool_call>\n<tool_call>\necho second\n</tool_call>' ;;
        mimo_two)   resp=$'Two checks.<tool_call><function=bash><parameter=command>echo first</parameter></function></tool_call>\n<tool_call><function=bash><parameter=command>echo second</parameter></function></tool_call>' ;;
        mimo_sameline) resp=$'<tool_call><function=bash><parameter=command>echo first</parameter></function></tool_call><tool_call><function=bash><parameter=command>echo second</parameter></function></tool_call>' ;;
    esac
    out=$(extract_code "$resp")
    ran=$(bash -c "$out" 2>"$WORK/notice")
    if [[ "$ran" == "first" ]] && grep -q 'truncated after first code block' "$WORK/notice" &&
        grep -q 'used tool-call markup' "$WORK/notice"; then
        ok "multiple calls ($shape): only the first runs, with both notices"
    else
        bad "multiple calls ($shape): only the first runs, with both notices" "ran=$ran notice=$(head -c 200 "$WORK/notice")"
    fi
    rm -f "$WORK/notice"
done
resp=$'<tool_call>\n<function=bash>\ncat <<\'DATA\'\n</tool_call>\n<tool_call>\nDATA\necho AFTER\n</function>\n</tool_call>'
ran=$(bash -c "$(extract_code "$resp")" 2>/dev/null)
[[ "$ran" == $'</tool_call>\n<tool_call>\nAFTER' ]] && ok "a call boundary inside a heredoc is data, not a cut" ||
    bad "a call boundary inside a heredoc is data, not a cut" "ran=$ran"

# A fence must win even when grep sees it before printf has finished writing.
# Use multiline padding well beyond pipe capacity and repeat under pipefail.
# The payload is passed through stdin, never bash -c (Linux argv size limit).
script=$(cat <<'SCRIPT'
cat <<'DATA'
<tool_call>
echo DATA_ONLY
</tool_call>
SCRIPT
)
padding=$(awk 'BEGIN { for (i = 0; i < 16000; i++) print "# padding 0123456789abcdef" }')
script="$script"$'\n'"$padding"$'\nDATA\necho AFTER'
resp=$'```bash\n'"$script"$'\n```'
for attempt in 1 2 3 4 5; do
    out=$(extract_code "$resp")
    if [[ "$out" == "$script" ]]; then
        ok "large fenced literal stays intact under pipefail (attempt $attempt)"
    else
        bad "large fenced literal stays intact under pipefail (attempt $attempt)"
    fi
done
resp=$'<tool_call>\n<function=bash>\n'"$script"$'\n</function>\n</tool_call>'
out=$(extract_code "$resp")
expected=$(printf '%s\n' "$script" | bash)
ran=$(printf '%s\n' "$out" | bash 2>"$WORK/notice")
if [[ "$ran" == "$expected" && "$out" == *"used tool-call markup"* ]]; then
    ok "large wrapped heredoc is preserved without sending the script through argv"
else
    bad "large wrapped heredoc is preserved without sending the script through argv"
fi

# CRLF: a Windows line ending must not survive into the extracted code, and
# must not stop the closing fence from being recognized.
resp=$'```bash\r\necho crlf\r\n```\r\n'
out=$(extract_code "$resp")
if [[ "$out" == "echo crlf" ]]; then
    ok "CRLF line endings are stripped from the extracted code"
else
    bad "CRLF line endings are stripped from the extracted code" "$(printf '%s' "$out" | cat -vet)"
fi

# Harness provenance lines ([served_by], [exit], [stdout], ...) pasted after a
# fenceless reply are structure, not code. Cut at the first one so metadata is
# never run as shell commands.
resp=$'echo one\n[served_by]\nXiaomi\n[exit] 0\n[stdout]\nnoise'
out=$(extract_code "$resp")
if [[ "$out" == *"echo one"* && "$out" != *"Xiaomi"* && "$out" != *"noise"* ]]; then
    ok "provenance trailer is cut from a fenceless reply"
else
    bad "provenance trailer is cut from a fenceless reply" "$(printf '%s' "$out" | head -c 160)"
fi

# The same words inside a fenced block are literal code and must survive.
resp=$'```bash\necho before\n[exit] 1\necho after\n```'
out=$(extract_code "$resp")
if [[ "$out" == $'echo before\n[exit] 1\necho after' ]]; then
    ok "provenance text inside a fence is literal code"
else
    bad "provenance text inside a fence is literal code" "$out"
fi

# A provenance word inside an unfenced heredoc or multiline quote is data.
# Compare all output, including the trailing command, and write the heredoc
# to a file so truncating its contents cannot look like a successful run.
for marker in served_by exec_s exit stdout stderr; do
    for quoting in heredoc single double; do
        case "$quoting" in
            heredoc) script=$(printf "cat <<'DATA' > '%s/literal'\nbefore\n[%s]\nafter\nDATA\ncat '%s/literal'\necho AFTER\n" "$WORK" "$marker" "$WORK") ;;
            single) script=$(printf "printf '%%s\\\\n' 'before\n[%s]\nafter'\necho AFTER\n" "$marker") ;;
            double) script=$(printf "printf '%%s\\\\n' \"before\n[%s]\nafter\"\necho AFTER\n" "$marker") ;;
        esac
        expected=$(printf '%s\n' "$script" | bash)
        out=$(extract_code "$script")
        ran=$(printf '%s\n' "$out" | bash 2>"$WORK/notice"); rc=$?
        if [[ "$rc" -eq 0 && "$ran" == "$expected" ]]; then
            ok "unfenced $quoting preserves [$marker] and the trailing command"
        else
            bad "unfenced $quoting preserves [$marker] and the trailing command" "rc=$rc ran=$ran"
        fi
    done
done

# A large discarded trailer must not make the upstream printf die on SIGPIPE.
resp=$'echo one\n[stdout]\n'"$padding"
out=$(extract_code "$resp")
ran=$(printf '%s\n' "$out" | bash 2>"$WORK/notice")
[[ "$ran" == one ]] && ok "a large provenance trailer is discarded" || bad "a large provenance trailer is discarded" "$ran"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
