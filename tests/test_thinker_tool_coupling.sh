#!/usr/bin/env bash
# tests/test_thinker_tool_coupling.sh — every stock tool promised to the mind
# must be forwarded into shellm's Docker sandbox.
#
# Why: _build_shellm_flags constructs the repeated --bin flags used by every
# thinker run. A tool can exist in bin/ and be advertised by the stock prompt
# and README while silently disappearing only in Docker. The model then records
# a false capability loss instead of doing the work (observed with focus).

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/id/memories" "$H/id/skills" "$H/id/kernel" \
         "$H/id/trajectories" "$H/id/workdir" "$H/id/chat"
printf 'default_send_from=operator\n' > "$H/id/chat/.chatrc"

export PATH="$REPO/bin:$REPO/tools:$PATH"
export IDENTITY_NAME=probe
export IDENTITY_DIR="$H/id"
export MEM_DIR="$H/id/memories"
export SKILLS_DIR="$H/id/skills"
export SKILLS_KERNEL_DIR="$H/id/kernel"
export TRAJ_DIR="$H/id/trajectories"
export TRAJ_ID=probe-root
export CHATRC="$H/id/chat/.chatrc"

# shellcheck disable=SC1091
source "$REPO/thinkers/_lib/common.sh"

flags=$(_build_shellm_flags "$IDENTITY_DIR" "$H/id/workdir")
mounted=""
expect_path=0
while IFS= read -r line; do
    if [[ "$expect_path" -eq 1 ]]; then
        mounted="${mounted}${line}"$'\n'
        expect_path=0
    elif [[ "$line" == "--bin" ]]; then
        expect_path=1
    fi
done <<< "$flags"

if printf '%s\n' "$flags" | grep -qxF "CHATRC=$H/id/chat/.chatrc"; then
    ok "identity CHATRC is forwarded into generated-code runs"
else
    bad "identity CHATRC is forwarded into generated-code runs" \
        "missing CHATRC=$H/id/chat/.chatrc"
fi

# These are the core/convenience executables README.md says the running mind
# uses. thinkers is the host dispatcher, so it intentionally is not staged into
# generated-code sandboxes.
required=(mem traj skills context llm shellm chat recap)
for tool in "${required[@]}"; do
    path=$(command -v "$tool" 2>/dev/null || true)
    if [[ -z "$path" ]]; then
        bad "stock tool '$tool' exists" "not found on the checkout PATH"
        continue
    fi
    if printf '%s' "$mounted" | grep -qxF "$path"; then
        ok "stock tool '$tool' is forwarded with --bin"
    else
        bad "stock tool '$tool' is forwarded with --bin" "missing $path"
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
