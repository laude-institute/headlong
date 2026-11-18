#!/usr/bin/env bash
# tests/test_skills_requires.sh — declared requirements must reach the
# eligibility gate in every natural YAML spelling, and a spelling the
# reader cannot treat as a list must never kill the render or pass the
# skill silently.
#
# Why: _extract_shelllm_meta read only same-line quoted JSON arrays
# (bins: ["curl"]). YAML block lists (key on one line, "- item" lines
# below) parsed as empty, so a skill's requirements were silently
# unenforced and it listed as eligible; an unquoted same-line array
# (bins: [curl]) killed jq, so `skills list` died mid-render; and the
# wake prompt's Skills section ran no requirements check at all, so
# ineligible skills were offered bare. This suite pins: block lists
# gate, quoted and unquoted same-line arrays gate, a block-list
# requirement that is met stays eligible, the footer names what is
# missing, --all and show --requires keep working, and the prompt
# annotates ineligible skills instead of offering them bare.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
export SKILLS_DIR="$H/skills" SKILLSRC="$H/none" SKILLS_KERNEL_DIR="" NO_COLOR=1
mkdir -p "$SKILLS_DIR/plain" "$SKILLS_DIR/envblk" "$SKILLS_DIR/binsblk" \
         "$SKILLS_DIR/mixed" "$SKILLS_DIR/badarr" "$SKILLS_DIR/jsonarr" \
         "$SKILLS_DIR/presentbin"
printf -- '---\nname: plain\ndescription: no requirements\n---\nBody.\n' > "$SKILLS_DIR/plain/SKILL.md"
# Block-list env: the shape the usage docs draw, minus the JSON brackets.
printf -- '---\nname: envblk\ndescription: needs env\nmetadata:\n  shelllm:\n    requires:\n      env:\n        - NO_SUCH_ENV_HARRIS\n---\nBody.\n' > "$SKILLS_DIR/envblk/SKILL.md"
# Block-list bins, quoted dash item.
printf -- '---\nname: binsblk\ndescription: needs a missing binary\nmetadata:\n  shelllm:\n    requires:\n      bins:\n        - "no-such-bin-harris"\n---\nBody.\n' > "$SKILLS_DIR/binsblk/SKILL.md"
# Two block lists at once; jq is present so only the env may be missing.
printf -- '---\nname: mixed\ndescription: one env and one binary\nmetadata:\n  shelllm:\n    requires:\n      env:\n        - NO_SUCH_ENV_HARRIS\n      bins:\n        - jq\n---\nBody.\n' > "$SKILLS_DIR/mixed/SKILL.md"
# Same-line unquoted flow array: valid YAML, invalid JSON. On the old
# reader this killed jq and the whole render died mid-list.
printf -- '---\nname: badarr\ndescription: bad array spelling\nmetadata:\n  shelllm:\n    requires:\n      bins: [no-such-bin-harris]\n---\nBody.\n' > "$SKILLS_DIR/badarr/SKILL.md"
# Same-line quoted JSON array: the one spelling the old reader handled.
printf -- '---\nname: jsonarr\ndescription: needs a missing binary\nmetadata:\n  shelllm:\n    requires:\n      bins: ["no-such-bin-harris"]\n---\nBody.\n' > "$SKILLS_DIR/jsonarr/SKILL.md"
# Block-list requirement that IS met: jq is on PATH for these tests.
printf -- '---\nname: presentbin\ndescription: needs a present binary\nmetadata:\n  shelllm:\n    requires:\n      bins:\n        - jq\n---\nBody.\n' > "$SKILLS_DIR/presentbin/SKILL.md"

SK="$REPO/bin/skills"
main_list() { sed '/Skipped (missing requirements)/,$d' <<<"$1"; }
footer()   { sed -n '/Skipped (missing requirements)/,$p' <<<"$1"; }

out=$( "$SK" list 2>&1 ); rc=$?
check "list render survives every spelling (exit 0)" test "$rc" -eq 0
check "plain skill with no requirements in main list" grep -q plain <<<"$(main_list "$out")"
check "block-list env skill out of the main list" bash -c '! grep -q envblk <<<"$(sed "/Skipped (missing requirements)/,\$d" <<<"$1")"' _ "$out"
check "footer names envblk and its missing env var" grep -Eq "envblk.*NO_SUCH_ENV_HARRIS|NO_SUCH_ENV_HARRIS.*envblk" <<<"$(footer "$out")"
check "block-list bins skill out of the main list" bash -c '! grep -q binsblk <<<"$(sed "/Skipped (missing requirements)/,\$d" <<<"$1")"' _ "$out"
check "footer names binsblk and its missing binary" grep -Eq "binsblk.*no-such-bin-harris|no-such-bin-harris.*binsblk" <<<"$(footer "$out")"
check "mixed skipped for env only, not for present jq" bash -c 'f=$(sed -n "/Skipped (missing requirements)/,\$p" <<<"$1"); grep -Eq "mixed.*(missing: NO_SUCH_ENV_HARRIS|NO_SUCH_ENV_HARRIS.*missing)" <<<"$f" && ! grep -Eq "mixed.*missing: jq" <<<"$f"' _ "$out"
check "unquoted flow array gates the skill, not the render" bash -c 'grep -Eq "badarr.*no-such-bin-harris|no-such-bin-harris.*badarr" <<<"$(sed -n "/Skipped (missing requirements)/,\$p" <<<"$1")"' _ "$out"
check "quoted JSON array still gates" grep -Eq "jsonarr.*no-such-bin-harris|no-such-bin-harris.*jsonarr" <<<"$(footer "$out")"
check "met block-list requirement stays eligible" bash -c 'grep -q presentbin <<<"$(sed "/Skipped (missing requirements)/,\$d" <<<"$1")" && ! grep -q presentbin <<<"$(sed -n "/Skipped (missing requirements)/,\$p" <<<"$1")"' _ "$out"

outa=$( "$SK" list --all 2>&1 )
check "list --all shows envblk with its missing env" grep -q "missing: NO_SUCH_ENV_HARRIS" <<<"$outa"

outr=$( "$SK" show badarr --requires 2>&1 ); rc=$?
check "show --requires exits 0 on the unquoted array" test "$rc" -eq 0
check "show --requires reads the unquoted array" grep -q no-such-bin-harris <<<"$outr"
outr2=$( "$SK" show envblk --requires 2>&1 )
check "show --requires reads the block list" grep -q NO_SUCH_ENV_HARRIS <<<"$outr2"
outr3=$( "$SK" show plain --requires 2>&1 )
check "show --requires still says none declared for plain" grep -q "No requirements declared" <<<"$outr3"

outp=$( "$SK" prompt 2>&1 ); rc=$?
check "prompt render exits 0" test "$rc" -eq 0
check "prompt offers the plain skill" grep -q plain <<<"$outp"
check "prompt offers the met-requirement skill bare" grep -q presentbin <<<"$outp"
check "prompt annotates the ineligible skill with what is missing" grep -Eq "envblk.*NO_SUCH_ENV_HARRIS|NO_SUCH_ENV_HARRIS.*envblk" <<<"$outp"

H2=$(mktemp -d)
mkdir -p "$H2/skills/osok2"
printf -- '---\nname: osok2\ndescription: os ok\nmetadata:\n  shelllm:\n    requires:\n      os: ["darwin", "linux"]\n---\nBody.\n' > "$H2/skills/osok2/SKILL.md"
out3=$(SKILLS_DIR="$H2/skills" "$SK" list 2>&1)
check "platform-covering os skill eligible, no footer" bash -c 'grep -q osok2 <<<"$1" && ! grep -q "Skipped" <<<"$1"' _ "$out3"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
