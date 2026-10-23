#!/usr/bin/env bash
# Exercise default-agent exclusion and explicit per-agent installation offline.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sc-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Start without caller identity settings, credentials or model configuration.
env -i HOME="$WORK" PATH="$REPO/bin:$REPO/tools:$PATH" \
    REPO="$REPO" WORK="$WORK" SHELLM_ENV=local bash <<'TEST'
set -euo pipefail
cd "$WORK"
identity new optional-test >/dev/null
export SKILLS_DIR="$WORK/.identities/optional-test/skills"
export SKILLS_KERNEL_DIR="$WORK/.identities/optional-test/kernel"
export SKILLSRC="$SKILLS_DIR/.skillsrc"
test ! -e "$REPO/skills/skill-compiler"
test ! -e "$SKILLS_DIR/skill-compiler"
skills prompt > before.txt
if grep -q 'skill-compiler' before.txt; then exit 1; fi
printf 'ok   default agent does not receive or advertise skill-compiler\n'
skills install "$REPO/contrib/skill-compiler" >/dev/null
test -x "$SKILLS_DIR/skill-compiler/skill-compiler"
skills prompt > after.txt
grep -q 'skill-compiler' after.txt
skills show skill-compiler > loaded.txt
grep -q 'explicit installation' loaded.txt
"$SKILLS_DIR/skill-compiler/skill-compiler" --help > help.txt
grep -q 'Validate a skill' help.txt
printf 'ok   explicit installation makes the skill available to the selected agent\n'
skills remove --force skill-compiler >/dev/null
test ! -e "$SKILLS_DIR/skill-compiler"
skills prompt > removed.txt
test -s removed.txt
if grep -q 'skill-compiler' removed.txt; then exit 1; fi
printf 'ok   removal stops advertising the skill\n'
TEST
