#!/usr/bin/env bash
# Small offline smoke test for the optional skill validator. No model calls.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sc-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

env -i HOME="$WORK/home" PATH="$REPO/bin:$REPO/tools:$PATH" \
    REPO="$REPO" WORK="$WORK" SHELLM_ENV=local bash <<'TEST'
set -euo pipefail
export HEADLONG_HOME="$WORK/state" SKILLS_DIR="$WORK/skills"
export SKILLS_KERNEL_DIR="$WORK/kernel" SKILL_AUTO_HARVEST=0
export SKILL_COMPILED_DIR="$WORK/reports" SC_TMP_BASE="$WORK/tmp"
export CALL_LOG="$WORK/model-calls" PROBE_LOG="$WORK/probes"
export REAL_MKTEMP
REAL_MKTEMP=$(command -v mktemp)
mkdir -p "$HOME" "$SKILLS_DIR/probe" "$SKILLS_KERNEL_DIR" "$WORK/stubs"
cd "$WORK"
SC="$REPO/contrib/skill-compiler/skill-compiler"

cat > "$SKILLS_DIR/probe/SKILL.md" <<'SKILL'
---
name: probe
description: Print a greeting.
---
Run `bash probe.sh` to print a greeting.
SKILL
cat > "$SKILLS_DIR/probe/probe.sh" <<'PROBE'
#!/usr/bin/env bash
printf 'probe\n' >> "$PROBE_LOG"
printf 'Hello from the test skill\n'
PROBE
cat > "$WORK/stubs/llm" <<'TEACHER'
#!/usr/bin/env bash
set -euo pipefail
cat > /dev/null
printf 'teacher\n' >> "$CALL_LOG"
printf '%s\n' '[{"name":"greeting","prompt":"Run the probe and report its greeting.","expect":"final","expect_contains":["Hello from the test skill"]}]'
TEACHER
cat > "$WORK/stubs/shellm" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
printf 'runner\n' >> "$CALL_LOG"
mkdir -p "$TRAJ_DIR"
printf '%s\n' \
    '{"type":"trajectory","step_id":"smoke-root"}' \
    '{"type":"shellm-run","step_id":"smoke-run"}' \
    '{"type":"final","run_id":"smoke-run","content":"Hello from the test skill"}' \
    > "$TRAJ_DIR/trajectory.jsonl"
printf 'smoke-run\n' > "$SHELLM_RUN_ID_OUT"
RUNNER
cat > "$WORK/stubs/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
if [[ "${FAIL_PROBE_TMP:-0}" == 1 && "$*" == *phrase-pool.* ]]; then exit 1; fi
exec "$REAL_MKTEMP" "$@"
MKTEMP
chmod +x "$WORK/stubs/llm" "$WORK/stubs/shellm" "$WORK/stubs/mktemp"
export PATH="$WORK/stubs:$PATH"

"$SC" compile --skill probe --num-tests 1 --max-iterations 1 > compile.log
jq -e '.summary.total == 1 and .summary.passed == 1 and
    .summary.verified == 1 and .summary.fail == 0 and .tests[0].pass' \
    "$SKILL_COMPILED_DIR/probe.json" > /dev/null
printf 'teacher\nrunner\n' > expected-calls
cmp expected-calls "$CALL_LOG"
test -s "$PROBE_LOG"
"$SC" show --skill probe > report.md
grep -q VERIFIED report.md
"$SC" list > list.txt
grep -qx probe list.txt
printf 'ok   one validation produces a successful saved report\n'

"$SC" clean --skill probe > /dev/null
test ! -e "$SKILL_COMPILED_DIR/probe.json"
test ! -e "$SKILL_COMPILED_DIR/probe.md"
test -z "$(ls -A "$SC_TMP_BASE")"
printf 'ok   reports and temporary runs clean up\n'

: > "$CALL_LOG"
: > "$PROBE_LOG"
for skill in ../probe slack; do
    if "$SC" compile --skill "$skill" > refusal.log 2>&1; then exit 1; fi
    grep -qE 'invalid skill name|compile skip-list' refusal.log
done
test ! -s "$CALL_LOG"
test ! -s "$PROBE_LOG"
printf 'ok   unsafe paths and known messaging skills are refused before execution\n'

for command in pool compile; do
    if FAIL_PROBE_TMP=1 "$SC" "$command" --skill probe > setup.log 2>&1; then exit 1; fi
done
test ! -s "$CALL_LOG"
test ! -s "$PROBE_LOG"
test ! -e "$SKILL_COMPILED_DIR/probe.json"
printf 'ok   failed private-directory creation stops probes and models\n'
TEST
