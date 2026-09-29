#!/usr/bin/env bash
# tests/test_chat_skip_guard.sh — `chat send --key` refuses a window that
# bin/papers-skip marked deliberately skipped, under every spelling of the
# key. Before this guard the DUE NOW line's own command sent on a window all
# the paper tools refused (scratch/skip-chat-hole-2026-09-27).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK="${SHELLM_TEST_WORK:-}"
if [[ -z "$WORK" ]]; then
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
else
    rm -rf "$WORK"; mkdir -p "$WORK"
fi

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

export PATH="$REPO/bin:$PATH"
export TRAJ_DIR="$WORK/traj"
mkdir -p "$TRAJ_DIR"

new_out=$(traj new --traj_dir "$TRAJ_DIR" --slug skip-guard-test)
tid=$(printf '%s\n' "$new_out" | head -1)
export TRAJ_ID="$tid"
export ROOT_TRAJ_ID="$tid"
export IDENTITY_NAME="tester"
export CHATRC="$WORK/.chatrc"
printf 'default_send_from=tester\n' > "$CHATRC"
export PAPERS_RECEIPTS_DIR="$WORK/receipts"
mkdir -p "$PAPERS_RECEIPTS_DIR"
printf 'key=breaktest/2026-09-26-1800\nreason=probe\n' > "$PAPERS_RECEIPTS_DIR/breaktest_2026-09-26-1800.skip"
cd "$WORK" || exit 1

msgs() { traj cat "$TRAJ_ID" --filter type=message --raw 2>/dev/null | wc -l; }

expect_refusal() { # desc key text [extra args...]
    local desc="$1" key="$2" text="$3"; shift 3
    local before after
    before=$(msgs)
    if chat send --from tester --to slack-U1-C1 --key "$key" "$@" "$text" >/dev/null 2>"$WORK/err"; then
        bad "$desc" "send succeeded, expected refusal"
        return
    fi
    if ! grep -qi "skipped" "$WORK/err"; then
        bad "$desc" "refused without naming the skip: $(cat "$WORK/err")"
        return
    fi
    after=$(msgs)
    if [[ "$after" == "$before" ]]; then ok "$desc"; else bad "$desc" "message step written despite refusal"; fi
}

expect_send() { # desc key text [extra args...]
    local desc="$1" key="$2" text="$3"; shift 3
    local before after
    before=$(msgs)
    if chat send --from tester --to slack-U1-C1 --key "$key" "$@" "$text" >/dev/null 2>"$WORK/err"; then
        after=$(msgs)
        if [[ "$after" -gt "$before" ]]; then ok "$desc"; else bad "$desc" "sent but no message step written"; fi
    else
        bad "$desc" "unexpected refusal: $(cat "$WORK/err")"
    fi
}

expect_refusal "canonical key with a skip record" "breaktest/2026-09-26-1800" "probe one"
expect_refusal "doubled-slash alias of the skipped window" "breaktest//2026-09-26-1800" "probe two"
expect_refusal "trailing-slash alias of the skipped window" "breaktest/2026-09-26-1800/" "probe three"
expect_refusal "extra-component alias of the skipped window" "breaktest/x/2026-09-26-1800" "probe four"
expect_refusal "skip holds even with --force" "breaktest/2026-09-26-1800" "probe five" --force
expect_send   "a window with no skip record sends" "breaktest/2026-09-26-1900" "normal one"
expect_send   "a non-window duty key sends" "1ab0deb4/polostan-history-2026-09-26" "normal two"

# Aliases the first fix missed (break pass 2026-09-27): a prefix, a dot
# prefix, a suffix, an id in the other case and a trailing space all carried
# the skipped window past the guard, and so did an unpadded window.
expect_refusal "prefix alias of the skipped window" "x/breaktest/2026-09-26-1800" "probe A"
expect_refusal "dot-prefix alias of the skipped window" "./breaktest/2026-09-26-1800" "probe B"
expect_refusal "suffix alias of the skipped window" "breaktest/2026-09-26-1800/x" "probe C"
expect_refusal "case alias of the skipped window" "BREAKTEST/2026-09-26-1800" "probe D"
expect_refusal "trailing-space alias of the skipped window" "breaktest/2026-09-26-1800 " "probe E"
expect_refusal "unpadded window alias of the skipped window" "breaktest/2026-9-6-1800" "probe F"
expect_send   "a duty key that only looks windowish still sends" "1ab0deb4/notes-2026-9-6-1800" "normal three"

# A skip record written in the other case still refuses the lowercase key.
printf 'key=BREAKTEST2/2026-09-26-2200\n' > "$PAPERS_RECEIPTS_DIR/BREAKTEST2_2026-09-26-2200.skip"
expect_refusal "a skip record in the other case refuses the lowercase key" "breaktest2/2026-09-26-2200" "probe G"

# The older PAPERS_RECEIPTS spelling is honored too (same rule as papers-receipt).
unset PAPERS_RECEIPTS_DIR
export PAPERS_RECEIPTS="$WORK/receipts2"
mkdir -p "$PAPERS_RECEIPTS"
printf 'key=breaktest/2026-09-26-2000\n' > "$PAPERS_RECEIPTS/breaktest_2026-09-26-2000.skip"
expect_refusal "PAPERS_RECEIPTS spelling of the receipts dir" "breaktest/2026-09-26-2000" "probe six"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
