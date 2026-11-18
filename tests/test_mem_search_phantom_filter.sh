#!/usr/bin/env bash
# test_mem_search_phantom_filter.sh — mem search gates model-named files
# against the store directory before printing them.
#
# Usage: tests/test_mem_search_phantom_filter.sh
#
# Why: the search ranker is a model, and on 2026-10-15 one minted a store
# entry that never existed: the house filename convention, a fresh hex id,
# a timestamp a day in the future, absent from disk, refused by mem show,
# gone on four of five byte-identical re-runs. The reply reached stdout
# unchecked, so a synthesized name stood in the listing beside real
# files. The fix reads the reply first and prints a line naming a file
# only if that file exists in the store; a line naming no file claims
# nothing about the store and passes through as spoken. Checks, with a
# stubbed llm returning canned replies: a phantom among real names is
# dropped and named on stderr while the real names print, an all-phantom
# reply drops every line and answers No matches found., a plain no-match
# reply passes through with no drop note, and names glued to bullets are
# still parsed and gated.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/bin" "$WORK/mem"
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
cat > "$LLM_STUB_PROMPT"
printf '%s\n' "$LLM_STUB_REPLY"
STUB
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export MEM_DIR="$WORK/mem" LLM_STUB_PROMPT="$WORK/prompt" MEM_SEARCH_HEARTBEAT_S=0

REAL1="2026-08-01-09-00-00_aa111111_a-real-memory-about-anchored-inbound-checks.md"
REAL2="2026-08-02-09-00-00_bb222222_a-second-real-memory-about-the-dispatcher.md"
PH1="2026-10-16-19-30-41_c9309824_the-check-does-not-own-its-own-data-it-only-reads-it-so-an-inbound-anchored-check-reads-a.md"
PH2="2026-10-16-20-00-00_9d1e2f30_a-fabricated-entry-the-store-never-held.md"
printf -- '---\nid: aa111111\nsummary: real one\ntype: memory\ncreated: 2026-08-01 09:00:00\n---\n\nAn anchored inbound check memory.\n' > "$MEM_DIR/$REAL1"
printf -- '---\nid: bb222222\nsummary: real two\ntype: memory\ncreated: 2026-08-02 09:00:00\n---\n\nA dispatcher memory.\n' > "$MEM_DIR/$REAL2"

# 1. Two real names and a phantom: the reals print, the phantom does not.
export LLM_STUB_REPLY="$REAL1: real one, about anchored checks
$REAL2: real two, about the dispatcher
$PH1: The check does not own its own data"
out=$(mem search "anchored checks" 2>"$WORK/err"); rc=$?
[[ "$rc" -eq 0 ]] && ok "mixed reply exits 0" || bad "mixed reply exits 0" "rc=$rc"
grep -qF "$REAL1" <<<"$out" && ok "real one prints" || bad "real one prints"
grep -qF "$REAL2" <<<"$out" && ok "real two prints" || bad "real two prints"
if grep -qF "$PH1" <<<"$out"; then bad "phantom not printed" "it reached the listing"; else ok "phantom not printed"; fi
grep -q "dropped 1 model-named entry" "$WORK/err" && ok "drop named on stderr" || bad "drop named on stderr" "$(tr '\n' ' ' < "$WORK/err" | cut -c1-90)"

# 2. An all-phantom reply: nothing prints but No matches found.
export LLM_STUB_REPLY="$PH1: fabricated one
$PH2: fabricated two"
out=$(mem search "anything" 2>"$WORK/err"); rc=$?
[[ "$rc" -eq 0 ]] && ok "all-phantom reply exits 0" || bad "all-phantom reply exits 0" "rc=$rc"
if grep -q "\.md" <<<"$out"; then bad "all-phantom listing is empty of names" "a .md reached stdout"; else ok "all-phantom listing is empty of names"; fi
grep -qF "No matches found." <<<"$out" && ok "all-phantom reply answers No matches found." || bad "all-phantom reply answers No matches found."
grep -q "dropped 2 model-named entries" "$WORK/err" && ok "both drops named on stderr" || bad "both drops named on stderr" "$(tr '\n' ' ' < "$WORK/err" | cut -c1-90)"

# 3. A plain no-match reply passes through with no drop note.
export LLM_STUB_REPLY="No matches found."
out=$(mem search "nothing here" 2>"$WORK/err"); rc=$?
[[ "$rc" -eq 0 ]] && ok "no-match reply exits 0" || bad "no-match reply exits 0" "rc=$rc"
grep -qF "No matches found." <<<"$out" && ok "no-match reply passes through" || bad "no-match reply passes through"
if grep -q "dropped" "$WORK/err"; then bad "no-match reply leaves no drop note" "$(tr '\n' ' ' < "$WORK/err" | cut -c1-90)"; else ok "no-match reply leaves no drop note"; fi

# 4. Names glued to bullets are parsed and gated the same way.
export LLM_STUB_REPLY="- $REAL1: real one behind a bullet
- $PH2: phantom behind a bullet"
out=$(mem search "bullet" 2>"$WORK/err"); rc=$?
[[ "$rc" -eq 0 ]] && ok "bulleted reply exits 0" || bad "bulleted reply exits 0" "rc=$rc"
grep -qF "$REAL1" <<<"$out" && ok "real name behind a bullet prints" || bad "real name behind a bullet prints"
if grep -qF "$PH2" <<<"$out"; then bad "phantom behind a bullet not printed" "it reached the listing"; else ok "phantom behind a bullet not printed"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
