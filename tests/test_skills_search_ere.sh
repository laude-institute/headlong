#!/usr/bin/env bash
# tests/test_skills_search_ere.sh — `skills search` must read the query as an
# extended regex. Both match sites (the installed listing and the remote
# listing) passed the raw query to plain grep, where a pipe meant as
# alternation is a literal character, so `chat|mem` printed "No local
# matches." in exactly the format a true empty prints. Born red on 2e39a3f:
# the three alternation arms fail, the bound arms pass.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
export SKILLS_DIR="$H/skills" SKILLSRC="$H/none" SKILLS_KERNEL_DIR="$H/kernel" NO_COLOR=1
export SKILLS_REMOTES="$H/remotes"
mkdir -p "$SKILLS_DIR/greet" "$SKILLS_DIR/chat" "$SKILLS_KERNEL_DIR/core" "$H/remotes/tg"
cat > "$SKILLS_DIR/greet/SKILL.md" <<'SK'
---
name: greet
description: Say hello politely
---
Greet.
SK
cat > "$SKILLS_DIR/chat/SKILL.md" <<'SK'
---
name: chat
description: Talk with people
---
Chat.
SK
cat > "$SKILLS_KERNEL_DIR/core/SKILL.md" <<'SK'
---
name: core
description: Always loaded
---
Kernel body.
SK
cat > "$H/remotes/tg/SKILL.md" <<'SK'
---
name: tg
description: Send files on Telegram
---
Remote body.
SK

run_search() { PATH="/usr/bin:/bin" "$REPO/tools/headlong-skills" search "$1" 2>&1; }

out=$(run_search 'greet|chat')
check "alternation matches the first installed skill"   grep -q 'greet' <<<"$out"
check "alternation matches the second installed skill"  grep -q 'chat' <<<"$out"

out=$(run_search 'tg|nothing')
check "alternation matches a remote skill"              grep -q 'tg' <<<"$out"

out=$(run_search 'greet')
check "single-word query still matches (bound)"         grep -q 'greet' <<<"$out"

out=$(run_search 'zzz|yyy')
check "no-match query reports no local matches (bound)" grep -q 'No local matches' <<<"$out"
check "no-match query reports no remote matches (bound)" grep -q 'No remote matches' <<<"$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
