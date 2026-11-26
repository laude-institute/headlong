#!/usr/bin/env bash
# tests/test_identity_delete_guard.sh — `identity delete` must refuse the
# active (default) identity under every spelling that reaches its directory:
# `ada/` (tab completion), `./ada`, `default` itself, or another symlink to
# it. Each of those used to slip past a raw string compare, and `rm -rf`
# then removed the live identity, or `docker rm -f` tore down its sandboxes.
# No LLM calls; docker is a recording shim.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

unset IDENTITY_NAME IDENTITY_DIR MEM_DIR SKILLS_DIR SKILLS_KERNEL_DIR TRAJ_ID TRAJ_DIR ROOT_TRAJ_ID
export HOME="$WORK/home" HEADLONG_HOME="$WORK/home/.headlong" HEADLONG_APP_DIR="$WORK/app"
mkdir -p "$HOME" "$HEADLONG_HOME" "$HEADLONG_APP_DIR" "$WORK/shim"
DOCKER_LOG="$WORK/docker.log"; : > "$DOCKER_LOG"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$DOCKER_LOG" > "$WORK/shim/docker"
chmod +x "$WORK/shim/docker"
export PATH="$WORK/shim:$REPO/bin:$REPO/tools:$PATH"

IDS="$HEADLONG_APP_DIR/.identities"
cd "$HEADLONG_APP_DIR" || exit 1
for n in ada bob carol; do
    identity new "$n" >/dev/null 2>&1 || { bad "identity new $n"; exit 1; }
    mkdir -p "$IDS/$n/.shellm/envs/sandbox"
    printf 'cid-%s\n' "$n" > "$IDS/$n/.shellm/envs/sandbox/container_id"
done
rm -f "$IDS/default"; ln -s ada "$IDS/default"
ln -s ada "$IDS/main"   # an operator-made alias of the active identity
cp -RP "$IDS" "$WORK/pristine"
reset() { rm -rf "$IDS"; cp -RP "$WORK/pristine" "$IDS"; : > "$DOCKER_LOG"; }

refused() {  # refused <label> <arg>: delete fails and ada is untouched
    local err rc
    reset
    err=$(identity delete "$2" 2>&1); rc=$?
    if [[ $rc -ne 0 && -f "$IDS/ada/info.txt" && "$(readlink "$IDS/default")" == ada ]] \
        && ! grep -q 'cid-ada' "$DOCKER_LOG"; then
        ok "$1"
    else
        bad "$1" "rc=$rc err=$err docker=$(cat "$DOCKER_LOG")"
    fi
}
refused "delete ada is still refused" "ada"
refused "delete ada/ (trailing slash) refuses the active identity" "ada/"
refused "delete ./ada refuses a path spelling" "./ada"
refused "delete default refuses the link to the active identity" "default"
refused "delete of an alias symlink to the active identity is refused" "main"
[[ -L "$IDS/main" ]] && ok "the refused alias link is left in place" || bad "alias left in place"

# Non-active identities still delete, with or without a trailing slash, and
# their sandboxes are torn down.
reset
identity delete bob >/dev/null 2>&1 && [[ ! -e "$IDS/bob" ]] && ok "delete bob removes a non-active identity" || bad "delete bob"
grep -q 'rm -f cid-bob' "$DOCKER_LOG" && ok "bob's sandbox container is removed" || bad "bob's container" "$(cat "$DOCKER_LOG")"
identity delete carol/ >/dev/null 2>&1 && [[ ! -e "$IDS/carol" ]] && ok "delete carol/ removes a non-active identity" || bad "delete carol/"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
