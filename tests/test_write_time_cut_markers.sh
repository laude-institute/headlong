#!/usr/bin/env bash
# tests/test_write_time_cut_markers.sh — write-time excerpt cuts are marked
#
# Usage: tests/test_write_time_cut_markers.sh
#
# Five sites bake a capped excerpt of a longer source into a durable row at
# write time, with no sign of the cut (the be080b0 family's sixth bite; PRs
# 240 to 244 fixed the render and store sites). No later renderer can mark
# what was already cut, so every downstream reader — the wake prompt, the
# tier summaries, chat pending — showed a half sentence as the whole text:
#
#   - responders/step: the reply-failed observation quotes the person's
#     message at 200 bytes; the deferral observation quotes the handed
#     request at 200 bytes; the replied observation quotes the reply at 200
#     bytes. Full text lives whole: the message in the raw log, the request
#     in the pending action row's request field, the reply in the raw log.
#   - monolith/step: the fallback error row bakes the run's last 3
#     non-blank stderr lines, each capped at 300 bytes, then deletes the
#     stderr file. The whole stderr streams live into the dispatcher's
#     thinker log (run/logs/monolith.log), so the route names it.
#   - retrieval/step: the recall observation embeds the first 3 mem-search
#     rows, capped at 300 bytes. The summaries live in the memory store.
#
# Every cap stays; every drop is now marked " (+N bytes more: <route>)"
# with the exact dropped byte count, and a fitting excerpt renders
# unchanged. The take is byte-safe both ways: drained through awk (a
# producer bigger than the pipe buffer cannot SIGPIPE under pipefail) and
# repaired at the boundary so a marked excerpt never ends inside a
# multibyte UTF-8 character. Stubbed llm/chat/mem/shellm; no LLM calls.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL RETRIEVAL_SEMANTIC RETRIEVAL_INDEX 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
RESPONDER="$REPO/thinkers/responder/step"
MONOLITH="$REPO/thinkers/monolith/step"
RETRIEVAL="$REPO/thinkers/retrieval/step"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=testid
THEM=andy
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000f1"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
printf 'test-token\n' > "$ID/run/dispatcher.token"

# --- stubs -----------------------------------------------------------------
mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do [[ "$prev" == "-s" ]] && printf '%s\n' "$a" > "${STUB_SYS_FILE:-/dev/null}"; prev="$a"; done
printf 'CALL\n' >> "${STUB_ARGS_FILE:-/dev/null}"
if [[ "${STUB_LLM_MODE:-}" == timeout ]]; then printf 'curl: (28) timed out\n' >&2; exit 1; fi
cat "$STUB_REPLY_FILE"
STUB
cat > "$WORK/stub/chat" <<'STUB'
#!/usr/bin/env bash
printf 'CHATCALL: %s\n' "$*" >> "${STUB_CALLS_FILE:-/dev/null}"
if [[ "$1" == "history" ]]; then
    if [[ -n "${STUB_HISTORY_FILE:-}" ]]; then cat "$STUB_HISTORY_FILE"; else printf '[]\n'; fi
else cat > "${STUB_SENT_FILE:-/dev/null}"; fi
STUB
chmod +x "$WORK/stub/llm" "$WORK/stub/chat"
export STUB_REPLY_FILE="$WORK/reply" STUB_SENT_FILE="$WORK/sent" STUB_CALLS_FILE="$WORK/calls"
export STUB_ARGS_FILE="$WORK/llm-args" STUB_SYS_FILE="$WORK/sys"

ENV_COMMON=(PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" IDENTITY_DIR="$ID" IDENTITY_NAME="$ME"
    MEM_DIR="$ID/memories" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home"
    SHELLM_MODEL=stub-model THINK_CONTEXT_TAIL=30 RESPONDER_PERSON_NOTES=0 MONOLITH_TIERED_MEMORY=0)
run_responder() {  # run_responder <trigger json> [extra env...]
    local trig="$1"; shift
    printf '%s' "$trig" | env "${ENV_COMMON[@]}" "$@" "$RESPONDER" >> "$WORK/step.log" 2>&1
}
now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
msg() {  # msg <step_id> <content> — append a message row to the trajectory
    printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' \
        "$1" "$THEM" "$ME" "$2" "$(now)" >> "$TRAJ"
}
fresh() { : > "$TRAJ"; printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(now)" >> "$TRAJ"; }

LONG250=$(printf 'm%.0s' $(seq 1 250))    # exactly 250 bytes, no digits (redaction no-op)

# --- 1. reply-failed: a 250-byte message excerpt marks the 50 dropped ------
fresh
msg trig-1 "$LONG250"
printf 'x\n' > "$STUB_REPLY_FILE"; : > "$STUB_SENT_FILE"
run_responder "$(grep -F '"step_id":"trig-1"' "$TRAJ")" STUB_LLM_MODE=timeout
row=$(jq -r 'select(.type=="observation" and .decision=="reply-failed") | .content' "$TRAJ" | head -1)
if [[ "$row" == *" (+50 bytes more: full message in the raw log)"* ]]; then
    ok "reply-failed: a 250-byte message excerpt ends (+50 bytes more: full message in the raw log)"
else
    bad "reply-failed: the 250-byte message excerpt marks the 50 dropped bytes" "${row: -80}"
fi
whole=$(jq -r 'select(.step_id=="trig-1") | .content' "$TRAJ")
[[ "$whole" == "$LONG250" ]] && ok "reply-failed: the route is honest, the raw log row keeps all 250 bytes" \
    || bad "reply-failed: the route is honest, the raw log row keeps all 250 bytes" "message row altered"

# --- 2. reply-failed: a fitting message renders with no marker -------------
fresh
msg trig-2 "short note that fits the cap"
printf 'x\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-2"' "$TRAJ")" STUB_LLM_MODE=timeout
row=$(jq -r 'select(.type=="observation" and .decision=="reply-failed") | .content' "$TRAJ" | head -1)
if [[ "$row" == *"short note that fits the cap"* && "$row" != *"bytes more"* ]]; then
    ok "reply-failed: a fitting excerpt carries no marker"
else
    bad "reply-failed: a fitting excerpt carries no marker" "${row: -60}"
fi

# --- 3. deferral: the handed request excerpt marks its drop, action whole -
fresh
msg trig-3 "can you check the deploy?"
printf 'DEFER: %s\nLet me look into that and get back to you.\n' "$LONG250" > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-3"' "$TRAJ")"
row=$(jq -r 'select(.type=="observation" and .decision=="replied") | .content' "$TRAJ" | head -1)
if [[ "$row" == *" (+50 bytes more: full request in the pending action row)"* ]]; then
    ok "deferral: the 250-byte request excerpt ends (+50 bytes more: full request in the pending action row)"
else
    bad "deferral: the request excerpt marks its dropped bytes" "${row: -80}"
fi
req=$(jq -r 'select(.type=="action") | .request' "$TRAJ" | head -1)
[[ "$req" == "$LONG250" ]] && ok "deferral: the route is honest, the action row keeps the whole request" \
    || bad "deferral: the route is honest, the action row keeps the whole request" "request row altered"

# --- 4. replied: the reply excerpt marks its drop ---------------------------
fresh
msg trig-4 "quick one"
printf '%s\n' "$LONG250" > "$STUB_REPLY_FILE"; : > "$STUB_SENT_FILE"
run_responder "$(grep -F '"step_id":"trig-4"' "$TRAJ")"
row=$(jq -r 'select(.type=="observation" and .decision=="replied") | .content' "$TRAJ" | head -1)
if [[ "$row" == *" (+50 bytes more: full reply in the raw log)"* ]]; then
    ok "replied: a 250-byte reply excerpt ends (+50 bytes more: full reply in the raw log)"
else
    bad "replied: the reply excerpt marks its dropped bytes" "${row: -80}"
fi
sent=$(cat "$STUB_SENT_FILE")
[[ "$sent" == *"$LONG250"* ]] && ok "replied: the route is honest, the send carries the whole reply" \
    || bad "replied: the route is honest, the send carries the whole reply" "sent text short"

# --- 5. multibyte: a clipped excerpt never ends inside a character ---------
MULTI="$(printf 'a%.0s' $(seq 1 121))$(printf 'é%.0s' $(seq 1 50))"   # 221 bytes, cut lands mid é
fresh
msg trig-5 "$MULTI"
printf 'x\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-5"' "$TRAJ")" STUB_LLM_MODE=timeout
row=$(jq -r 'select(.type=="observation" and .decision=="reply-failed") | .content' "$TRAJ" | head -1)
if [[ -n "$row" ]] && printf '%s' "$row" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    ok "multibyte: the marked observation decodes as valid UTF-8"
else
    bad "multibyte: the marked observation decodes as valid UTF-8" "row absent or invalid"
fi
if [[ "$row" =~ \ \([+][0-9]+\ bytes\ more:\ full\ message\ in\ the\ raw\ log\) ]]; then
    prefix=${row%% (+*}
    if [[ "$prefix" == *é ]]; then
        ok "multibyte: the clipped excerpt ends on a whole character before the marker"
    else
        bad "multibyte: the clipped excerpt ends on a whole character before the marker" "ends mid character"
    fi
else
    bad "multibyte: the clipped excerpt carries the byte-drop marker" "${row: -60}"
fi

# --- 6. monolith: the error row's stderr tail marks both drops -------------
MO_ID="$WORK/moid"
MO_TRAJ_ID="cafe0000-0000-0000-0000-0000000000f2"
mkdir -p "$MO_ID/memories" "$MO_ID/trajectories/$MO_TRAJ_ID" "$MO_ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$MO_TRAJ_ID" > "$MO_ID/info.txt"
MO_TRAJ="$MO_ID/trajectories/$MO_TRAJ_ID/trajectory.jsonl"
printf 'test-token\n' > "$MO_ID/run/dispatcher.token"

mkdir -p "$WORK/mstub"
cat > "$WORK/mstub/shellm" <<'STUB'
#!/usr/bin/env bash
printf 'drop one\n' >&2
printf 'drop two\n' >&2
printf 'c%.0s' $(seq 1 350) >&2; printf '\n' >&2
printf 'short line four\n' >&2
printf 'e%.0s' $(seq 1 400) >&2; printf '\n' >&2
exit 1
STUB
for t in identity mem recap; do printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/mstub/$t"; done
chmod +x "$WORK/mstub"/*

setsid_cmd=""
command -v setsid >/dev/null 2>&1 && setsid_cmd=setsid
run_monolith() {  # run_monolith <stub-name>
    IDENTITY_DIR="$MO_ID" IDENTITY_NAME="$ME" MEM_DIR="$MO_ID/memories" \
    TRAJ_DIR="$MO_ID/trajectories" TRAJ_ID="$MO_TRAJ_ID" ROOT_TRAJ_ID="$MO_TRAJ_ID" \
    THINKER_NAME=monolith THINK_MODEL=stub MONOLITH_TIERED_MEMORY=0 RELATED_MEMORIES=0 \
    PATH="$WORK/mstub:$REPO/bin:$REPO/tools:$PATH" \
    $setsid_cmd bash "$MONOLITH" >> "$WORK/monolith.log" 2>&1
}

: > "$MO_TRAJ"
printf '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}' | run_monolith
err=$(jq -c 'select(.type=="error" and .reason=="run-failed")' "$MO_TRAJ" | head -1)
[[ -n "$err" ]] && ok "monolith: a failed run records the error row" || bad "monolith: a failed run records the error row" "no error row"
st=$(jq -r '.stderr_tail // empty' <<<"$err")
[[ "$st" == *" (+50 bytes more: full line in run/logs/monolith.log)"* ]] \
    && ok "monolith: a 350-byte stderr line marks (+50 bytes more: full line in run/logs/monolith.log)" \
    || bad "monolith: the 350-byte stderr line marks its 50 dropped bytes" "${st: -90}"
[[ "$st" == *" (+100 bytes more: full line in run/logs/monolith.log)"* ]] \
    && ok "monolith: a 400-byte stderr line marks (+100 bytes more: full line in run/logs/monolith.log)" \
    || bad "monolith: the 400-byte stderr line marks its 100 dropped bytes" "${st: -90}"
[[ "$st" == *" (+2 more stderr lines dropped; full stderr in run/logs/monolith.log)"* ]] \
    && ok "monolith: 2 dropped older stderr lines are counted with the log route" \
    || bad "monolith: the dropped older stderr lines are counted" "${st: -90}"

# --- 7. monolith: a fitting stderr tail carries no marker ------------------
cat > "$WORK/mstub/shellm" <<'STUB'
#!/usr/bin/env bash
printf 'one short line\n' >&2
printf 'two short line\n' >&2
exit 1
STUB
chmod +x "$WORK/mstub/shellm"
: > "$MO_TRAJ"
printf '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}' | run_monolith
st=$(jq -r 'select(.type=="error") | .stderr_tail // empty' "$MO_TRAJ" | head -1)
if [[ "$st" == *"one short line"* && "$st" != *"bytes more"* && "$st" != *"more stderr lines"* ]]; then
    ok "monolith: a fitting stderr tail carries no marker"
else
    bad "monolith: a fitting stderr tail carries no marker" "$st"
fi

# --- 8. retrieval: the mem-search rows mark both drops ---------------------
R_ID="$WORK/rid"
R_TRAJ_ID="cafe0000-0000-0000-0000-0000000000f3"
mkdir -p "$R_ID/memories" "$R_ID/trajectories/$R_TRAJ_ID"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$R_TRAJ_ID" > "$R_ID/info.txt"
R_TRAJ="$R_ID/trajectories/$R_TRAJ_ID/trajectory.jsonl"
: > "$R_TRAJ"
printf -- '---\nid: aaaa1111\nsummary: docker on this mac is colima\ntype: fact\n---\nBind mounts fail.\n' > "$R_ID/memories/20260801_aaaa_colima.md"

mkdir -p "$WORK/rstub"
# 5 search rows, each exactly 120 bytes, generated with a pinned form so
# the dropped-count math below is computed from the fixture, never hand-summed.
python3 - "$WORK/mem-search-rows" <<'PYROWS'
import sys
with open(sys.argv[1], "w") as f:
    for L in "abcde":
        f.write(L * 120 + "\n")
PYROWS
cat > "$WORK/rstub/mem" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "search" ]]; then
    if [[ -n "${STUB_MEM_ROWS_FILE:-}" ]]; then cat "$STUB_MEM_ROWS_FILE"; exit 0; fi
    cat "$MEM_SEARCH_ROWS_FILE"
fi
STUB
chmod +x "$WORK/rstub/mem"
export MEM_SEARCH_ROWS_FILE="$WORK/mem-search-rows"

run_retrieval() {  # run_retrieval <step json> [extra env...]
    local sj="$1"; shift
    printf '%s' "$sj" | env IDENTITY_DIR="$R_ID" IDENTITY_NAME="$ME" MEM_DIR="$R_ID/memories" \
        TRAJ_DIR="$R_ID/trajectories" TRAJ_ID="$R_TRAJ_ID" SKILLS_DIR="$R_ID/skills" \
        SKILLS_KERNEL_DIR="$R_ID/kernel" HOME="$WORK/home" RETRIEVAL_SEMANTIC=1 \
        PATH="$WORK/rstub:$REPO/bin:$PATH" "$@" "$RETRIEVAL"
}
trigger='{"type":"thought","step_id":"s-1","content":"Why does the docker bind mount of this path silently fail on colima?"}'
run_retrieval "$trigger"
rob=$(jq -r 'select(.type=="observation" and .source=="retrieval") | .content' "$R_TRAJ" | head -1)
# 3 kept rows joined by single spaces: 3*120 + 2 = 362 bytes against a
# 300-byte cap, the dropped count computed from the fixture itself.
sem_kept=$(awk 'NF && ++k <= 3' "$MEM_SEARCH_ROWS_FILE" | tr '\n' ' ' | sed 's/ $//')
sem_total=$(printf '%s' "$sem_kept" | LC_ALL=C wc -c | tr -d ' ')
sem_dropped=$(( sem_total - 300 ))
[[ "$rob" == *" (+${sem_dropped} bytes more: full summaries live in the memory store)"* ]] \
    && ok "retrieval: the 362-byte search excerpt ends (+${sem_dropped} bytes more: full summaries live in the memory store)" \
    || bad "retrieval: the search excerpt marks its dropped bytes" "${rob: -90}"
[[ "$rob" == *" (+2 more search rows dropped; their summaries live in the memory store)"* ]] \
    && ok "retrieval: 2 dropped search rows are counted with the store route" \
    || bad "retrieval: the dropped search rows are counted" "${rob: -90}"

# --- 9. retrieval: fitting search rows carry no marker ---------------------
printf 'one small row\nother small row\n' > "$WORK/mem-rows"
rm -f "$R_ID/retrieval/seen"
run_retrieval "$trigger" STUB_MEM_ROWS_FILE="$WORK/mem-rows"
rob=$(jq -r 'select(.type=="observation" and .source=="retrieval") | .content' "$R_TRAJ" | tail -1)
if [[ "$rob" == *"one small row"* && "$rob" != *"bytes more"* && "$rob" != *"more search rows"* ]]; then
    ok "retrieval: fitting search rows carry no marker"
else
    bad "retrieval: fitting search rows carry no marker" "${rob: -80}"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
