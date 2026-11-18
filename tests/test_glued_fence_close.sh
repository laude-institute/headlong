#!/usr/bin/env bash
# Glued closing fences: a fence fused to the end of a command line, with the
# next block's opener attached. Shape measured from a live run (2026-11-14):
# a closing fence glued after 'head -25' killed ten commands in a row with
# exit 2. Extraction and stream boundaries only: nothing model-generated is
# executed, only bash -n on extracted code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
for fn in script_parses strip_markup_suffix normalize_toolcall_markup extract_code; do
    sed -n "/^${fn}()/,/^}/p" "$REPO/bin/shellm"
done > "$WORK/extractor"
sed -n '/^_fs_buf=/,/^# Print a visible-text/p' "$REPO/bin/llm" > "$WORK/stopper"
# shellcheck disable=SC1091
source "$WORK/extractor"
# shellcheck disable=SC1091
source "$WORK/stopper"
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# 1. The production shape, verbatim from the dead run: block opens properly,
# then the closing fence is glued to a command with the next opener fused on.
cat > "$WORK/reply" <<'EOF'
I will look at the layout first.
```bash
cd /opt/shellm/app
echo "=== files touching jsonl rows ==="
grep -rln "jsonl" bin tools thinkers 2>/dev/null | head -25```bash
cd /opt/shellm/app
echo SECOND_BLOCK_BODY
```
PROSE_AFTER
EOF
err="$WORK/err"; code=$(extract_code "$(cat "$WORK/reply")" 2>"$err")
if [[ "$code" == *'head -25'* && "$code" != *'```'* && "$code" != *SECOND_BLOCK_BODY* && "$code" != *PROSE_AFTER* ]]; then ok 'glued close: prefix kept, fence text and second block dropped'; else bad 'glued close: prefix kept, fence text and second block dropped'; fi
[[ "$code" == *'truncated after first code block'* ]] && ok 'glued close with fused opener fires TRUNCATED' || bad 'glued close with fused opener fires TRUNCATED'
script_parses "$code" && ok 'glued close: extracted code parses' || bad 'glued close: extracted code parses'

# 2. Bare glued close at end of response: closes cleanly, no TRUNCATED owed.
cat > "$WORK/reply" <<'EOF'
Some prose.
```bash
echo FIRST
cat file | wc -l```
EOF
err="$WORK/err2"; code=$(extract_code "$(cat "$WORK/reply")" 2>"$err")
if [[ "$code" == *'wc -l'* && "$code" == *'echo FIRST'* && "$code" != *'```'* ]]; then ok 'bare glued close keeps prefix, drops fence text'; else bad 'bare glued close keeps prefix, drops fence text'; fi
grep -q TRUNCATED "$err" && bad 'bare glued close must not fire TRUNCATED' || ok 'bare glued close fires no TRUNCATED'
script_parses "$code" && ok 'bare glued close code parses' || bad 'bare glued close code parses'

# 3. Heredoc: a glue-looking line inside heredoc data is data, not a close.
cat > "$WORK/reply" <<'EOF'
```bash
cat <<'END_DOC'
echo line```bash
END_DOC
printf AFTER_HEREDOC
```
EOF
err="$WORK/err3"; code=$(extract_code "$(cat "$WORK/reply")" 2>"$err")
if [[ "$code" == *'echo line```bash'* && "$code" == *AFTER_HEREDOC* ]]; then ok 'glued fence inside heredoc stays data'; else bad 'glued fence inside heredoc stays data'; fi
script_parses "$code" && ok 'heredoc fixture parses' || bad 'heredoc fixture parses'

# 4. Backtick pairs in real code are not a glued close.
cat > "$WORK/reply" <<'EOF'
prose
```bash
echo START
now=$(date)
echo `date` > f
```
EOF
code=$(extract_code "$(cat "$WORK/reply")" 2>"$WORK/err4")
if [[ "$code" == *'`date`'* && "$code" == *'echo START'* ]]; then ok 'backtick pairs in code survive'; else bad 'backtick pairs in code survive'; fi
script_parses "$code" && ok 'backtick fixture parses' || bad 'backtick fixture parses'

# 5. A backtick run longer than three is degenerate markup, not a fence.
cat > "$WORK/reply" <<'EOF'
prose
```bash
echo a
echo b````
echo TAIL
```
EOF
code=$(extract_code "$(cat "$WORK/reply")" 2>"$WORK/err5")
if [[ "$code" == *'````'* && "$code" == *TAIL* ]]; then ok 'four-backtick run is not a fence'; else bad 'four-backtick run is not a fence'; fi

# 6. Stream consumer: _fs_line returns 0 (block closed) on the glue line.
_fs_in=0; _fs_hd=()
_fs_line '```bash' ; _fs_line 'echo hi'
if _fs_line 'grep -rln jsonl bin | head -25```bash'; then ok 'stream consumer ends at glued close'; else bad 'stream consumer ends at glued close'; fi
_fs_in=0; _fs_hd=()
_fs_line '```bash'; _fs_line 'echo a'
if _fs_line 'echo x````'; then bad 'stream consumer: long run is not a fence'; else ok 'stream consumer: long run is not a fence'; fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
