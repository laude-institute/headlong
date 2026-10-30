#!/usr/bin/env bash
# test_mem_search_ghost_rows.sh — `mem search` must not print rows naming files
# that do not exist in the store.
#
# Usage: tests/test_mem_search_ghost_rows.sh
#
# Why: the search sends candidates to a model and streams the model's reply
# to stdout with no grounding check (2026-10-30). A hallucinated row then
# reaches downstream callers — kin and dupe gates, recall, any store-fact
# read — as a store fact. Grounding keys on the row's eight-hex memory id:
# a row whose id the store knows passes even when the model redates or
# shortens the filename; a row whose id the store does not know falls back
# to the named file and is dropped when that file does not exist. Checks,
# with a stubbed llm: a real filename passes, a ghost is filtered, a
# filename-like prose line passes, an all-ghost reply is refused as a
# result ("No matches found." rather than empty success), and rows naming
# a real memory by id survive both a wrong date and a date-less filename.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
mk() {  # mk <name> <summary> <body>
    printf -- '---\nsummary: %s\ntype: memory\n---\n\n%s\n' "$2" "$3" > "$MEM_DIR/$1.md"
}

mkdir -p "$WORK/bin" "$WORK/mem"
export MEM_DIR="$WORK/mem"

# --- 1. real rows pass, ghost rows are filtered -------------------------
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
cat > "$LLM_STUB_PROMPT"
cat <<'REPLY'
2026-08-21-00-00-02.md: A real memory about Noah.
2026-09-11-11-57-15_f12466cd_how-to-mint-a-work-order-and-have-it-not-be-minted-twice.md: How to mint a work order and have it not be minted twice.
The best file for this query is the one about disk usage.
REPLY
STUB
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH" LLM_STUB_PROMPT="$WORK/prompt"

mk "2026-08-21-00-00-02" "Noah intro" "New Slack guest Noah joined the channel."
out=$(mem search "Noah") 2>/dev/null
echo "$out" | grep -q "2026-08-21-00-00-02" \
    && ok "real row reaches stdout" \
    || bad "real row reaches stdout" "got: $(printf '%s' "$out" | head -5)"
if printf '%s' "$out" | grep -q "f12466cd"; then
    bad "ghost row filtered" "f12466cd printed"
else
    ok "ghost row filtered"
fi
printf '%s' "$out" | grep -q "disk usage" \
    && ok "prose line kept" \
    || bad "prose line kept" "prose line dropped"

# --- 2. all-ghost reply is refused as a result --------------------------
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
cat > "$LLM_STUB_PROMPT"
cat <<'REPLY'
2026-09-11-11-57-15_f12466cd_how-to-mint-a-work-order-and-have-it-not-be-minted-twice.md: How to mint a work order and have it not be minted doubly.
2026-09-11-12-00-00_deadbeef_a-second-ghost-that-never-existed.md: Another ghost row.
REPLY
STUB
chmod +x "$WORK/bin/llm"

out=$(mem search "marching orders") 2>&1; rc=$?
if printf '%s' "$out" | grep -q "No matches found"; then
    ok "all-ghost reply refused"
else
    bad "all-ghost reply refused" "rc=$rc out: $(printf '%s' "$out" | head -3)"
fi

# --- 3. the id key keeps rows the filename check would drop -----------
mk "2026-09-23-00-38-26_d80cbb98_a-correction-reaches-the-next-wake" "Six channels" "A correction reaches the next wake through six channels."
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
cat > "$LLM_STUB_PROMPT"
cat <<'REPLY'
2026-01-01-00-00-00_d80cbb98_a-correction-reaches-the-next-wake.md: A correction reaches the next wake.
d80cbb98_a-correction-reaches-the-next-wake.md: A correction reaches the next wake.
REPLY
STUB
chmod +x "$WORK/bin/llm"

out=$(mem search "correction channels") 2>/dev/null
c1=$(printf '%s' "$out" | grep -c "d80cbb98") || true
if [[ "${c1:-0}" -ge 2 ]]; then
    ok "redated and date-less rows naming a real id kept"
else
    bad "redated and date-less rows naming a real id kept" "got ${c1:-0} of 2 rows: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
