#!/usr/bin/env bash
# tests/test_workspace_runtime.sh — the Runtime line and Workspace section of
# the wake prompt (thinkers/_lib/common.sh: _runtime_line, _workspace_section).
# Both run under the monolith's set -euo pipefail, so every edge case must exit
# 0: no git checkout, no workdir, empty workdir, a WORKSPACE.md present.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

run() {  # run <bash snippet> with the library sourced under set -e
    bash -c "set -euo pipefail; export PATH=\"$REPO/bin:\$PATH\"; source \"$REPO/thinkers/_lib/common.sh\"; $1" 2>&1
}

# Runtime line from the repo checkout.
out=$(IDENTITY_DIR="$W/none" run '_runtime_line; echo RC=$?')
grep -q '^Runtime: headlong [0-9a-f]\{7,\} (.*), checked out 20[0-9][0-9]-' <<<"$out" && ok "runtime line: commit, subject, checkout time" || bad "runtime line" "$out"
grep -q 'thinkers synced' <<<"$out" && bad "no sync time without an identity thinkers dir" || ok "no sync time without an identity thinkers dir"
mkdir -p "$W/id/thinkers/monolith"; printf 'x\n' > "$W/id/thinkers/monolith/step"
out=$(IDENTITY_DIR="$W/id" run '_runtime_line')
grep -q 'your thinkers synced 20[0-9][0-9]-' <<<"$out" && ok "sync time from the newest identity thinker file" || bad "sync time" "$out"

# No git checkout behind the shellm on PATH: prints nothing, exits 0.
mkdir -p "$W/fake/bin"
for t in shellm traj mem; do printf '#!/bin/sh\n' > "$W/fake/bin/$t"; chmod +x "$W/fake/bin/$t"; done
out=$(bash -c "set -euo pipefail; export PATH=\"$W/fake/bin:\$PATH\"; source \"$REPO/thinkers/_lib/common.sh\"; _runtime_line; echo RC=\$?" 2>&1)
[[ "$out" == "RC=0" ]] && ok "no git checkout: empty line, rc 0" || bad "no git checkout" "$out"

# Workspace section.
out=$(run "_workspace_section '$W/missing'; echo RC=\$?")
[[ "$out" == "RC=0" ]] && ok "missing workdir: nothing, rc 0" || bad "missing workdir" "$out"
mkdir -p "$W/wd"
out=$(run "_workspace_section '$W/wd'")
grep -q '^Workspace: ' <<<"$out" && grep -q '^- 0 loose files' <<<"$out" && grep -q 'No WORKSPACE.md yet' <<<"$out" \
    && ok "empty workdir: header, zero loose files, WORKSPACE.md invite" || bad "empty workdir" "$out"
mkdir -p "$W/wd/notes/deep" "$W/wd/papers" "$W/wd/.git" "$W/wd/__pycache__"
printf 'n\n' > "$W/wd/notes/a.md"; printf 'n\n' > "$W/wd/notes/deep/b.md"; printf 'n\n' > "$W/wd/papers/p.html"
printf 'l\n' > "$W/wd/loose.txt"; printf 'h\n' > "$W/wd/.hidden"; printf 'c\n' > "$W/wd/__pycache__/x.pyc"; printf 'g\n' > "$W/wd/.git/HEAD"
out=$(run "_workspace_section '$W/wd'")
grep -q '^- notes/ 2 files' <<<"$out" && ok "directory counts are recursive" || bad "recursive count" "$out"
grep -q '^- 1 loose files' <<<"$out" && ok "hidden top-level files are not loose files" || bad "loose count" "$out"
grep -qE '__pycache__|\.git/' <<<"$out" && bad "hidden and __pycache__ dirs are skipped" || ok "hidden and __pycache__ dirs are skipped"
[[ "$(grep -c '^- .*/ ' <<<"$out")" -eq 2 ]] && ok "one line per directory" || bad "dir lines" "$out"
out=$(run '_coarse_count 7; echo; _coarse_count 99; echo; _coarse_count 100; echo; _coarse_count 3459; echo; _coarse_count 1808; echo; _coarse_count 5000 5000')
[[ "$out" == $'7\n99\nabout 100\nabout 3500\nabout 1800\n5000+' ]] && ok "counts round to two significant figures from 100 up (cache-stable prefix)" || bad "coarse counts" "$out"
printf 'notes/ = research\npapers/ = cached HTML\n' > "$W/wd/WORKSPACE.md"
out=$(run "_workspace_section '$W/wd'")
grep -q '^notes/ = research' <<<"$out" && ! grep -q 'No WORKSPACE.md' <<<"$out" && ok "WORKSPACE.md head replaces the invite" || bad "WORKSPACE.md head" "$out"
for i in $(seq 1 15); do mkdir -p "$W/wd/d$i"; printf 'x\n' > "$W/wd/d$i/f"; done
out=$(WORKSPACE_DIRS=5 run "_workspace_section '$W/wd'")
[[ "$(grep -c '^- .*/ ' <<<"$out")" -eq 5 ]] && grep -q '^- and 12 more directories' <<<"$out" && ok "directory list is capped with a remainder line" || bad "dir cap" "$out"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
