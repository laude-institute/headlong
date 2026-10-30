#!/usr/bin/env bash
# test_mem_search_ghost_rows.sh — `mem search` must not print rows naming files
# that do not exist in the store.
#
# Usage: tests/test_mem_search_ghost_rows.sh
#
# Why: the search sends candidates to a model and streams the model's reply
# to stdout with no check that a returned row names a real store file
# (2026-10-30). A hallucinated row then reaches downstream callers — kin and
# dupe gates, recall, any store-fact read — as a store fact. Checks, with a
# stubbed llm that returns one real filename, one ghost filename that exists
# in no store, and one filename-like line that is really prose: the real row
# passes, the ghost is filtered, the prose line passes, and a reply that is
# all ghosts is itself refused as a result (the engine answers "No matches
# found." rather than an empty success).

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
