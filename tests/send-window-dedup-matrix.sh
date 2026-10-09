#!/usr/bin/env bash
# tests/send-window-dedup-matrix.sh: duplicate-send guard matrix for bin/chat.
# Three guards are exercised. The keyed duty guard: a --key names the one duty a
# send fulfils, so a second send carrying the same key is refused however the
# text is reworded (on 2026-09-18 one papers post went out five times in three
# hours past the exact-text guard because each retry was reworded). The 24h
# identical-text guard for unkeyed sends. And one reply per trigger step.
# --force is the deliberate override and must keep working. Every case runs
# against a throwaway HOME and trajectory, so the matrix is safe to run anywhere
# and never touches a live identity state.
set -u

here=$(cd "$(dirname "$0")" && pwd)
CHAT=${CHAT:-$here/../bin/chat}
if [ ! -x "$CHAT" ]; then
  echo "send-window-dedup-matrix: no executable at $CHAT" >&2
  exit 2
fi

REFUSE_RE="refus|skipping duplicate|already sent|already has a reply|duty is done"
pass=0
fail=0
skip=0
report=""

fresh_state() {
  ROOT=$(mktemp -d /tmp/sddm.XXXXXXXX) || exit 2
  HOME=$ROOT
  TRAJ_DIR=$ROOT/traj
  TRAJ_ID=sddm-$RANDOM-$RANDOM
  ROOT_TRAJ_ID=$TRAJ_ID
  CHATRC=$ROOT/chatrc
  IDENTITY_NAME=audel
  export HOME TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID CHATRC IDENTITY_NAME
  unset CHAT_REPEAT_WINDOW CHAT_REPLY_REPEAT_WINDOW 2>/dev/null
  mkdir -p "$TRAJ_DIR/$TRAJ_ID"
  printf '{"step_id":"%s","type":"trajectory","ts":"%s"}\n' "$TRAJ_ID" \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$TRAJ_DIR/$TRAJ_ID/trajectory.jsonl"
  printf 'default_send_from=%s\n' "${IDENTITY_NAME:-audel}" > "$CHATRC"
}

# outcome: REFUSE when the guard spoke, ALLOW on a clean send, ERROR when the
# command failed for some other reason, which must never count as a pass.
outcome() {
  if printf %s "${OUT:-}" | grep -qiE "$REFUSE_RE"; then
    echo REFUSE
  elif [ ${RC:-1} -eq 0 ]; then
    echo ALLOW
  else
    echo ERROR
  fi
}

_send() {
  local to=$1 key=$2 text=$3
  shift 3
  local args=(send --to "$to")
  if [ "$key" != "-" ]; then args+=(--key "$key"); fi
  if [ $# -gt 0 ]; then args+=("$@"); fi
  if [ "$MODE" = stdin ]; then
    OUT=$(printf %s "$text" | "$CHAT" "${args[@]}" 2>&1)
  else
    OUT=$("$CHAT" "${args[@]}" "$text" 2>&1)
  fi
  RC=$?
}

_reply() {
  local step=$1 to=$2 text=$3
  shift 3
  local args=(reply)
  if [ $# -gt 0 ]; then args+=("$@"); fi
  args+=(--reply-to "$step" "$to")
  if [ "$MODE" = stdin ]; then
    OUT=$(printf %s "$text" | "$CHAT" "${args[@]}" 2>&1)
  else
    OUT=$("$CHAT" "${args[@]}" "$text" 2>&1)
  fi
  RC=$?
}

expect() {
  local desc=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    pass=$((pass+1))
    report="$report
PASS  $desc"
  else
    fail=$((fail+1))
    report="$report
FAIL  $desc (want $want, got $got)"
  fi
}

skipcase() {
  skip=$((skip+1))
  report="$report
SKIP  $1"
}

MODE=arg
fresh_state
_send slack-U0DDTEST - "bootstrap probe $RANDOM"
if [ "$(outcome)" != ALLOW ]; then
  MODE=stdin
  fresh_state
  _send slack-U0DDTEST - "bootstrap probe $RANDOM"
fi
if [ "$(outcome)" != ALLOW ]; then
  echo "bootstrap failed: this binary would not send at all" >&2
  printf %s "$OUT" >&2
  exit 2
fi

A=slack-U0DDTEST
B=slack-U0DDTEST2

fresh_state
K="1ab0ded4/matrix-$RANDOM"
_send "$A" "$K" "papers alpha one"
expect "a first keyed send goes out" ALLOW "$(outcome)"
_send "$A" "$K" "papers alpha one"
expect "the same key repeated is refused" REFUSE "$(outcome)"

fresh_state
K="1ab0ded4/matrix-$RANDOM"
_send "$A" "$K" "papers alpha one"
_send "$A" "$K" "the same duty in other words"
expect "the same key with different text is refused" REFUSE "$(outcome)"

fresh_state
_send "$A" "1ab0ded4/m1-$RANDOM" "papers alpha one"
_send "$A" "1ab0ded4/m2-$RANDOM" "papers beta two"
expect "a different key with different text is a new duty, allowed" ALLOW "$(outcome)"

fresh_state
_send "$A" "1ab0ded4/m1-$RANDOM" "papers alpha one"
_send "$A" "1ab0ded4/m2-$RANDOM" "papers alpha one"
expect "a different key with identical text is refused, the text guard also stands" REFUSE "$(outcome)"

fresh_state
_send "$A" - "plain identical text"
_send "$A" - "plain identical text"
expect "unkeyed identical text inside a day is refused" REFUSE "$(outcome)"

fresh_state
_send "$A" - "plain text one"
_send "$A" - "plain text two"
expect "unkeyed different text is allowed" ALLOW "$(outcome)"

fresh_state
K="1ab0ded4/matrix-$RANDOM"
_send "$A" "$K" "papers alpha one"
_send "$A" "$K" "papers alpha one" --force
expect "the same key with force is allowed" ALLOW "$(outcome)"

fresh_state
_send "$A" - "plain identical text"
_send "$A" - "plain identical text" --force
expect "an unkeyed repeat with force is allowed" ALLOW "$(outcome)"

fresh_state
K="1ab0ded4/matrix-$RANDOM"
_send "$A" "$K" "papers alpha one"
_send "$B" "$K" "papers alpha one"
expect "the same key to a second recipient is refused, the duty is done" REFUSE "$(outcome)"

fresh_state
T=trig-$RANDOM
_reply "$T" "$A" "answer one"
if [ "$(outcome)" = ALLOW ]; then
  _reply "$T" "$A" "answer one in other words"
  expect "a second reply on one trigger is refused" REFUSE "$(outcome)"
  _reply "trig-$RANDOM" "$A" "answer one in other words"
  expect "a reply to another trigger is allowed" ALLOW "$(outcome)"
else
  skipcase "reply guard cases skipped, a reply needs a real trigger step here"
fi

printf %s "$report"
echo ""
echo "cases: pass=$pass fail=$fail skip=$skip"
if [ $fail -eq 0 ]; then exit 0; else exit 1; fi
