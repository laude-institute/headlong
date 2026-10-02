#!/usr/bin/env bash
# test_mem_search.sh — `mem search` sends the model candidates, not the store
#
# Usage: tests/test_mem_search.sh
#
# Why: the search used to concatenate every memory file into one request.
# For a mature identity that was 700KB (about 200K tokens): 44 cents a
# search on the mind's model, slower than shellm's 30s inactivity limit
# (billed, then killed), and a cheap model given that haystack returned the
# first files it saw (2026-09-03). Now a local keyword score picks the top
# MEM_SEARCH_TOP files and the model reads only those. Checks, with a stubbed
# llm that records what it was sent: the matching files reach the model and
# the filler does not, the candidate count is capped, rare terms outrank
# common ones, a query with no overlap falls back to the newest files, and
# the call carries the fast model and a roomy output cap.

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
printf '%s\n' "$*" > "$LLM_STUB_ARGS"
cat > "$LLM_STUB_PROMPT"
echo "stub reply"
STUB
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export MEM_DIR="$WORK/mem" LLM_STUB_ARGS="$WORK/args" LLM_STUB_PROMPT="$WORK/prompt"

# 60 filler memories about unrelated things, then a few targets. Filenames
# carry a timestamp so "newest" is well defined.
mk() {  # mk <name> <summary> <body>
    printf -- '---\nsummary: %s\ntype: memory\n---\n\n%s\n' "$2" "$3" > "$MEM_DIR/$1.md"
}
for i in $(seq -w 1 60); do
    mk "2026-08-01-00-00-$i" "Filler note $i" "The build ran and the tests passed on the box. Nothing else to report today."
done
mk "2026-08-20-00-00-01" "host-health checks" "The host-health probe checks disk, memory, and the dispatcher unit. Noah asked about it once."
mk "2026-08-21-00-00-02" "Noah intro" "New Slack guest Noah Ziems joined the channel; Braden asked me to introduce myself."
mk "2026-08-22-00-00-03" "Noah reply" "Noah Ziems acked the RLM reply. Last word his; do not follow up."
mk "2026-08-23-00-00-04" "recent unrelated" "A note about the weather on the box, which is always the same."

sent_files() { grep -o '^=== .*\.md ===' "$LLM_STUB_PROMPT" | sed 's/^=== //; s/ ===$//'; }

# --- 1. targets reach the model, filler does not, count is capped ---------
MEM_SEARCH_TOP=5 mem search "Noah Ziems" >/dev/null 2>&1; rc=$?
n=$(sent_files | wc -l | tr -d ' ')
if [[ "$rc" -eq 0 ]] && sent_files | grep -q "2026-08-21-00-00-02" && sent_files | grep -q "2026-08-22-00-00-03" \
   && ! sent_files | grep -q "2026-08-01-00-00-0[1-9]" && [[ "$n" -le 5 ]]; then
    ok "search sends the matching memories and caps the candidates ($n of 64 files sent)"
else
    bad "search sends the matching memories and caps the candidates" "rc=$rc sent: $(sent_files | tr '\n' ' ')"
fi
if grep -q '^Search these memories for: Noah Ziems' "$LLM_STUB_PROMPT" && grep -q 'Noah Ziems acked' "$LLM_STUB_PROMPT"; then
    ok "candidates are sent in full with the query"
else
    bad "candidates are sent in full with the query"
fi

# --- 2. a rare term outranks a common one ----------------------------------
# "tests" is in all 60 filler files, "host-health" in one: the one wins.
MEM_SEARCH_TOP=1 mem search "tests host-health" >/dev/null 2>&1
if [[ "$(sent_files)" == "2026-08-20-00-00-01.md" ]]; then
    ok "rare term outranks a common one (IDF weighting)"
else
    bad "rare term outranks a common one" "sent: $(sent_files | tr '\n' ' ')"
fi

# --- 3. no overlap at all: newest files ------------------------------------
MEM_SEARCH_TOP=3 mem search "zzz qqq" >/dev/null 2>&1
if [[ "$(sent_files | tr '\n' ' ')" == "2026-08-22-00-00-03.md 2026-08-23-00-00-04.md " ]] || [[ "$(sent_files | tail -1)" == "2026-08-23-00-00-04.md" && "$(sent_files | wc -l | tr -d ' ')" == "3" ]]; then
    ok "no term overlap falls back to the newest files"
else
    bad "no term overlap falls back to the newest files" "sent: $(sent_files | tr '\n' ' ')"
fi

# --- 4. the call: fast model when set, roomy output cap always -------------
SHELLM_FAST_MODEL="z-ai/glm-5.3-flash" mem search "Noah" >/dev/null 2>&1
if grep -q -- '-m z-ai/glm-5.3-flash' "$LLM_STUB_ARGS" && grep -q -- '-t 16000' "$LLM_STUB_ARGS"; then
    ok "fast model and a 16000 token output cap are passed"
else
    bad "fast model and a 16000 token output cap are passed" "$(cat "$LLM_STUB_ARGS")"
fi
MEM_SEARCH_MAX_TOKENS=4000 mem search "Noah" >/dev/null 2>&1
if ! grep -q -- ' -m ' "$LLM_STUB_ARGS" && grep -q -- '-t 4000' "$LLM_STUB_ARGS"; then
    ok "no fast model means the default model; the cap is tunable"
else
    bad "no fast model means the default model; the cap is tunable" "$(cat "$LLM_STUB_ARGS")"
fi

# --- 5. heartbeat while the model is slow ------------------------------------
# shellm kills a command silent for 30s; a reasoning model can think that long.
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null; sleep 1.2; echo "slow reply"
STUB
mk "2026-08-24-00-00-05" "Noah again" "Noah asked about the heartbeat."
hb_out=$(MEM_SEARCH_HEARTBEAT_S=0.3 mem search "Noah" 2>&1 >/dev/null | grep -c "waiting for the model")
if [[ "$hb_out" -ge 2 ]]; then
    ok "a slow model gets a heartbeat on stderr ($hb_out lines in 1.2s)"
else
    bad "a slow model gets a heartbeat on stderr" "got $hb_out"
fi
hb_off=$(MEM_SEARCH_HEARTBEAT_S=0 mem search "Noah" 2>&1 >/dev/null | grep -c "waiting for the model")
[[ "$hb_off" -eq 0 ]] && ok "heartbeat can be disabled" || bad "heartbeat can be disabled" "got $hb_off"
if ! pgrep -f "printf 'mem search: waiting" >/dev/null 2>&1; then ok "no heartbeat process left behind"; else bad "no heartbeat process left behind"; fi

# --- 6. empty store ----------------------------------------------------------
rm -f "$MEM_DIR"/*.md
out=$(mem search "anything" 2>&1)
if [[ "$out" == *"No memories stored"* ]]; then ok "empty store says so"; else bad "empty store says so" "$out"; fi

# --- 7. a wedged model call is cut at the bound (issue 119) ---------------
# The heartbeat feeds the host's inactivity watchdog by design, so a model
# call that never returns is cut by nothing else and the wake wedges behind
# it. Stage 2 carries its own deadline now. The orphan check reads captured
# stderr after a settle: a file that stays quiet means the heartbeat cleanup
# ran. No process-table check; pgrep -f matches the runner's own line.
mkdir -p "$WORK/mem4"; export MEM_DIR="$WORK/mem4"
mk "2026-09-16-00-00-06" "zanzibar note" "A note about the zanzibar dispatcher."
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null; sleep 30
STUB
start=$SECONDS
out=$(MEM_SEARCH_TIMEOUT_S=1 MEM_SEARCH_HEARTBEAT_S=0.2 timeout 10 mem search "zanzibar" 2>"$WORK/err7"); rc=$?
elapsed=$((SECONDS - start))
sz7=$(wc -c < "$WORK/err7"); sleep 1; sz7b=$(wc -c < "$WORK/err7")
if [[ "$rc" -eq 124 && "$elapsed" -le 5 ]] && grep -q "no reply from the model within 1s" "$WORK/err7" \
   && [[ "$sz7b" -eq "$sz7" ]]; then
    ok "a wedged model call is cut at MEM_SEARCH_TIMEOUT_S, exits 124, cleans its heartbeat"
else
    bad "a wedged model call is cut at MEM_SEARCH_TIMEOUT_S" "rc=$rc elapsed=$elapsed err=$sz7/$sz7b"
fi

# MEM_SEARCH_TIMEOUT_S=0 restores the old unbounded wait.
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null; sleep 1.5; echo "unbounded reply"
STUB
out=$(MEM_SEARCH_TIMEOUT_S=0 mem search "zanzibar" 2>"$WORK/err8"); rc=$?
if [[ "$rc" -eq 0 && "$out" == "unbounded reply" ]] && ! grep -q "no reply" "$WORK/err8"; then
    ok "MEM_SEARCH_TIMEOUT_S=0 keeps the unbounded wait"
else
    bad "MEM_SEARCH_TIMEOUT_S=0 keeps the unbounded wait" "rc=$rc out=$out"
fi

# Give later sections back the recording stub.
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$LLM_STUB_ARGS"
cat > "$LLM_STUB_PROMPT"
echo "stub reply"
STUB

# BM25 scoring (2026-09-04): a term once in a short file outranks the same
# term once in a long file, and `mem prefilter` exposes the stage-1 ranking.
mkdir -p "$WORK/mem2"; export MEM_DIR="$WORK/mem2"
printf -- '---\nid: a\nsummary: s\ntype: note\ncreated: 2026-08-01 00:00:00\n---\n\nshort note about the dispatcher token\n' > "$MEM_DIR/2026-08-01-00-00-00_a_short.md"
{ printf -- '---\nid: b\nsummary: l\ntype: note\ncreated: 2026-08-01 00:00:00\n---\n\ndispatcher token appears once here.\n'; for _ in $(seq 60); do printf 'filler words about many things and other items and more of the same\n'; done; } > "$MEM_DIR/2026-08-01-00-00-01_b_long.md"
top=$(mem prefilter "dispatcher token" --top 1 | xargs -n1 basename)
[[ "$top" == *_a_short.md ]] && ok "a short file outranks a long one with the same single match (length normalised)" || bad "length normalisation" "got $top"
n=$(mem prefilter "dispatcher token" | wc -l | tr -d ' ')
[[ "$n" == 2 ]] && ok "mem prefilter lists every matching file, best first" || bad "mem prefilter lists matches" "got $n"
z=$(mem prefilter "zzz qqq" | wc -l | tr -d ' ')
[[ "$z" == 0 ]] && ok "mem prefilter prints nothing with no term overlap" || bad "prefilter no overlap" "got $z"


# --- a big store must not SIGPIPE stage 1's own sort ----------------------
# `head -n $top` after `sort` exits early and the writer dies on the closed
# pipe: exit 2, "sort: write failed: Broken pipe", under pipefail. Live
# twice on 2026-10-02 on a 250-file store; a 3000-file store (more ranked
# lines than a pipe buffer holds) killed 26 of 26 trials before the fix,
# `mem search` included. The cut is `awk NR <= n`, which drains the sort.
mkdir -p "$WORK/membig"; export MEM_DIR="$WORK/membig"
awk -v d="$MEM_DIR" 'BEGIN {
    for (i = 1; i <= 3000; i++) {
        f = sprintf("%s/2026-08-05-00-00-%04d.md", d, i)
        printf "---\nid: %04x\nsummary: filler\ntype: note\n---\n\nneedle occurrence in a padded body long enough to score\n", i > f
        close(f)
    }}'
pipes=0; badrc=0; last=""
for _ in $(seq 6); do
    last=$(mem prefilter needle --top 40 2>"$WORK/pf.err"); rc=$?
    [[ "$rc" -eq 0 ]] || badrc=$((badrc+1))
    grep -q "Broken pipe" "$WORK/pf.err" && pipes=$((pipes+1))
done
n=$(printf '%s\n' "$last" | grep -c .)
if [[ "$pipes" -eq 0 && "$badrc" -eq 0 && "$n" -eq 40 ]]; then
    ok "prefilter ranks a 3000-file store without killing its sort (6 trials)"
else
    bad "prefilter survives a big store" "broken_pipes=$pipes nonzero_rc=$badrc lines=$n"
fi

# `until:` survives `mem edit` (2026-09-05): a todo shortlist appended to
# during the day must still expire that night.
mkdir -p "$WORK/mem3"; export MEM_DIR="$WORK/mem3"
mem add --type todo --until 2026-09-30 "shortlist: first candidate" >/dev/null 2>&1
f=$(ls "$MEM_DIR"/*.md | head -1); id=$(sed -n 's/^id: //p' "$f")
mem edit "$id" "shortlist: first candidate
- second candidate" >/dev/null 2>&1
f=$(ls "$MEM_DIR"/*.md | head -1)
grep -q '^until: 2026-09-30$' "$f" && ok "mem edit keeps the until: expiry" || bad "mem edit keeps until" "$(sed -n '1,8p' "$f")"
grep -q 'second candidate' "$f" && ok "mem edit replaced the body" || bad "mem edit body"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
