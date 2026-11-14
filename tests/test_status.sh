#!/usr/bin/env bash
# tests/test_status.sh — status.sh reports an install read-only, and the
# process patterns in headlong-killall / uninstall.sh / status.sh agree.
#
# Usage: tests/test_status.sh

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

# --- pattern parity (headlong-killall is the source of truth) ---------------
# eval, not `source <(...)`: bash 3.2 (macOS /bin/bash) reads an empty file
# from a sourced process substitution and the arrays come out empty.
extract() { bash -c 'eval "$(sed -n "/^PATTERNS=(/,/^)/p" "$1")"; printf "%s\n" "${PATTERNS[@]}"' _ "$1"; }
K=$(extract "$REPO/tools/headlong-killall"); S=$(extract "$REPO/status.sh"); U=$(extract "$REPO/uninstall.sh")
check "status.sh PATTERNS == headlong-killall PATTERNS"   test -n "$K" -a "$K" = "$S"
check "uninstall.sh PATTERNS == headlong-killall PATTERNS" test -n "$K" -a "$K" = "$U"
KD=$(sed -n "s/^    PATTERNS+=('\(.*\)')$/\1/p" "$REPO/tools/headlong-killall")
SD=$(sed -n "s/^DASH_PAT='\(.*\)'$/\1/p" "$REPO/status.sh")
UD=$(sed -n "s/^DASH_PAT='\(.*\)'$/\1/p" "$REPO/uninstall.sh")
check "dash pattern: killall == status.sh"     test -n "$KD" -a "$KD" = "$SD"
check "dash pattern: killall == uninstall.sh"  test -n "$KD" -a "$KD" = "$UD"
# the dash pattern must NOT match a shell that merely mentions headlong-web
check_not "dash pattern ignores 'systemctl show headlong-web'" bash -c '[[ "bash -c systemctl show headlong-web -p NRestarts" =~ $1 ]]' _ "$SD"
check "dash pattern matches uv run launch"   bash -c '[[ "uv run --project /x/app/web headlong-web /x/app" =~ $1 ]]' _ "$SD"
check "dash pattern matches venv entry"      bash -c '[[ "/y/.venv/bin/headlong-web /y/app" =~ $1 ]]' _ "$SD"

# --- empty HOME, piped like `curl | bash` from outside any checkout -----------------
H0="$WORK/h0"; mkdir -p "$H0"
out=$(cd "$H0" && HOME="$H0" HEADLONG_HOME="$H0/.headlong" PREFIX="$H0/.local/bin" bash < "$REPO/status.sh" 2>&1); rc=$?
check "empty HOME: exits 0"                  test "$rc" -eq 0
check "empty HOME: says not installed"       grep -q "not installed" <<<"$out"
check "empty HOME: processes section"        grep -q "Headlong processes on this machine" <<<"$out"
check "--help exits 0"                       bash "$REPO/status.sh" --help
check_not "unknown option errors"            bash "$REPO/status.sh" --bogus

# --- a one-liner-shaped install ----------------------------------------------------
H="$WORK/h"; APP="$H/.headlong/app"; mkdir -p "$H/.headlong" "$H/.local/bin"
git clone -q "$REPO" "$APP" 2>/dev/null || { bad "clone"; exit 1; }
rm -rf "$APP/tui"
( cd "$APP" && HOME="$H" HEADLONG_HOME="$H/.headlong" PREFIX="$H/.local/bin" bash install.sh --symlinks --no-init >/dev/null 2>&1 ) || { bad "install"; exit 1; }
( cd "$APP" && HOME="$H" PATH="$APP/bin:$APP/tools:$PATH" identity new ada --default >/dev/null 2>&1 ) || { bad "identity new"; exit 1; }
ln -s "$H/.local/bin/persona" "$H/.local/bin/ada"
printf 'OPENROUTER_API_KEY=sk-or-v1-0123456789abcdef0123456789abcdef\nSHELLM_MODEL=anthropic/claude-sonnet-4.5\n' > "$H/.headlong/.env"
before=$(find "$H" -newer "$REPO/status.sh" -type f 2>/dev/null | wc -l)
out=$(HOME="$H" HEADLONG_HOME="$H/.headlong" PREFIX="$H/.local/bin" bash "$REPO/status.sh" 2>&1); rc=$?
check "install: exits 0"                     test "$rc" -eq 0
check "install: checkout + commit"           grep -qE "checkout:   $APP   \(commit [0-9a-f]{7,}" <<<"$out"
check "install: state home + key name only"  grep -q "state home: $H/.headlong   (.env has: OPENROUTER_API_KEY; model anthropic/claude-sonnet-4.5)" <<<"$out"
check_not "install: key value never printed" grep -q "sk-or-v1-0123" <<<"$out"
check "install: tools count + agent command" grep -qE "tools:      [0-9]+ of [0-9]+ in $H/.local/bin; agent commands: ada" <<<"$out"
check "install: identity line, mind stopped" grep -q "ada (default): mind stopped" <<<"$out"
check "install: dash stopped"                grep -q "^  stopped" <<<"$out"
check "install: commands use full paths off-PATH" bash -c 'grep -q "bug report bundle:   $2/.local/bin/ada bugreport" <<<"$1" && grep -q "pause ada:           $2/.local/bin/ada stop" <<<"$1" && grep -q "export PATH=\"$2/.local/bin:" <<<"$1" && grep -q "uninstall.sh | bash" <<<"$1"' _ "$out" "$H"
out2=$(HOME="$H" HEADLONG_HOME="$H/.headlong" PREFIX="$H/.local/bin" PATH="$H/.local/bin:$PATH" bash "$REPO/status.sh" 2>&1)
check "install: bare commands when on PATH"  bash -c 'grep -q "pause ada:           ada stop" <<<"$1" && ! grep -q "export PATH=" <<<"$1"' _ "$out2"
# read-only: a fake dispatcher pid that is alive (this shell) shows as running, and nothing was written
mkdir -p "$APP/.identities/ada/run"; printf '%s\n' "$$" > "$APP/.identities/ada/run/dispatcher.pid"
out=$(HOME="$H" HEADLONG_HOME="$H/.headlong" PREFIX="$H/.local/bin" bash "$REPO/status.sh" 2>&1)
check "install: live dispatcher pid -> mind running" grep -q "ada (default): mind running (dispatcher pid $$)" <<<"$out"
check "read-only: no new files under HOME"   test "$(find "$H" -newer "$REPO/status.sh" -type f 2>/dev/null | grep -vc dispatcher.pid)" -le "$before"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
