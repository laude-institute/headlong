#!/usr/bin/env bash
# Usage: tests/test_indented_fence_close.sh
# Extraction and stream boundaries only: no model-generated text is executed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
for fn in script_parses strip_markup_suffix normalize_toolcall_markup extract_code; do
    sed -n "/^$fn() {$/,/^}$/p" "$REPO/bin/shellm"
done > "$WORK/extractor"
sed -n '/^_fs_buf=/,/^# Print a visible-text/p' "$REPO/bin/llm" > "$WORK/stopper"
# shellcheck disable=SC1091
source "$WORK/extractor"
# shellcheck disable=SC1091
source "$WORK/stopper"
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check_fixture() {
    local label="$1" reply code line closed=0
    reply=$(cat "$WORK/reply")
    code=$(extract_code "$reply")
    if [[ "$code" == *INSIDE_FIRST* && "$code" != *OUTSIDE_PROSE* && "$code" != *SECOND_BLOCK* ]]; then ok "$label extraction stays in first block"; else bad "$label extraction stays in first block"; fi
    _fs_buf=""; _fs_in=0; _fs_hd=(); _fs_bytes=0
    while IFS= read -r line; do
        if _fs_line "${line%$'\r'}"; then closed=1; break; fi
    done < "$WORK/reply"
    if [[ "$closed" == 1 && "$line" != *OUTSIDE_PROSE* && "$line" != *SECOND_BLOCK* ]]; then ok "$label streaming recognizes close"; else bad "$label streaming recognizes close"; fi
}
for indent in '' ' ' '  ' '   ' $'\t'; do
    printf '%s```bash\nprintf INSIDE_FIRST\n%s```\nOUTSIDE_PROSE\n```bash\nprintf SECOND_BLOCK\n```\n' "$indent" "$indent" > "$WORK/reply"
    check_fixture "indent ${#indent}"
done
for tag in sh shell bash; do
    printf 'prose then ```%s\nprintf INSIDE_FIRST\n   ```  \nOUTSIDE_PROSE\n' "$tag" > "$WORK/reply"
    check_fixture "$tag appended opener"
done
printf '```\nprintf INSIDE_FIRST\n   ```\nOUTSIDE_PROSE\n' > "$WORK/reply"
check_fixture 'bare opener'
printf '   ```bash\nprintf INSIDE_FIRST\n   ```\nOUTSIDE_PROSE\n' | awk '{printf "%s\r\n",$0}' > "$WORK/reply"
check_fixture CRLF
cat > "$WORK/reply" <<'EOF'
   ```bash
cat <<'END_DOC'
   ```
INSIDE_FIRST
```bash
END_DOC
printf AFTER_HEREDOC
   ```
OUTSIDE_PROSE
EOF
code=$(extract_code "$(cat "$WORK/reply")")
if [[ "$code" == *AFTER_HEREDOC* && "$code" == *INSIDE_FIRST* && "$code" != *OUTSIDE_PROSE* ]]; then ok 'heredoc fences remain data'; else bad 'heredoc fences remain data'; fi
_fs_in=0; _fs_hd=(); closed=0; n=0
while IFS= read -r line; do
    n=$((n+1)); if _fs_line "$line"; then closed="$n"; break; fi
done < "$WORK/reply"
[[ "$closed" == 8 ]] && ok 'stream ignores fences inside heredoc' || bad 'stream ignores fences inside heredoc'
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
