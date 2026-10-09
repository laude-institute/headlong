#!/usr/bin/env bash
# tests/test_skill_compiler.sh — offline checks for skills/skill-compiler: the
# compile skip-list refuses side-effect skills before any model call, a missing
# skill dies cleanly, the phrase pool carries the tool's own output vocabulary,
# the cache is self-describing with POOL-EXACT / POOL-FRAGMENT / INVENTED literal
# labels and VERIFIED only on pool-attested literals, and the shipped script
# carries no identity-specific absolute paths. No LLM calls, no network: the
# teacher and the test runner are stubs on PATH.
#
# Usage: tests/test_skill_compiler.sh

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SC="$REPO/skills/skill-compiler/skill-compiler"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sc-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/stubs"
mkdir -p "$STUB"

cat > "$STUB/llm" <<'STUBLEOF'
#!/usr/bin/env bash
[ -n "${STUB_LLM_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LLM_LOG"
if [ "${STUB_MODE:-}" = "many" ]; then
  cat <<'JSONM'
[{"name":"many-dropped","prompt":"Run the skill and report what it prints.","expect":"final","expect_contains":["zeta phrase 09 stable output"]}]
JSONM
  exit 0
fi
if [ "${STUB_MODE:-}" = "quote" ]; then
  cat <<'JSONQ'
[{"name":"greet-quote-fold","prompt":"Run the greeting skill and report what it prints.","expect":"final","expect_contains":["sed \"s/<[^>]*>//g\""]}]
JSONQ
  exit 0
fi
cat <<'JSON'
[
  {"name":"greet-pool-exact","prompt":"Run the greeting skill and report what it prints.","expect":"final","expect_contains":["Hello, phrase-pool world!"]},
  {"name":"greet-pool-fragment","prompt":"Run the greeting skill and report what it prints.","expect":"final","expect_contains":["phrase-pool world"]},
  {"name":"greet-invented","prompt":"Run the greeting skill and report what it prints.","expect":"final","expect_contains":["ZzyzxNotInPool"]}
]
JSON
STUBLEOF

cat > "$STUB/shellm" <<'STUBLEOF'
#!/usr/bin/env bash
[ -n "${STUB_SHELLM_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_SHELLM_LOG"
: "${TRAJ_DIR:?stub shellm needs TRAJ_DIR}"
mkdir -p "$TRAJ_DIR"
if [ "${STUB_MODE:-}" = "many" ]; then
  {
    printf '%s\n' '{"type":"shell-output","stdout":"zeta phrase 09 stable output"}'
    printf '%s\n' '{"type":"final","content":"Reported. zeta phrase 09 stable output."}'
  } > "$TRAJ_DIR/stub-run.jsonl"
  exit 0
fi
if [ "${STUB_MODE:-}" = "quote" ]; then
  {
    printf '%s\n' '{"type":"shell-output","stdout":"stripped with sed '"'"'s/<[^>]*>//g'"'"'"}'
    printf '%s\n' '{"type":"final","content":"stripped with sed '"'"'s/<[^>]*>//g'"'"'"}'
  } > "$TRAJ_DIR/stub-run.jsonl"
  exit 0
fi
{
  printf '%s\n' '{"type":"shell-output","stdout":"Hello, phrase-pool world! | phrase-pool world | ZzyzxNotInPool"}'
  printf '%s\n' '{"type":"final","content":"Reported. Hello, phrase-pool world! and phrase-pool world and ZzyzxNotInPool."}'
} > "$TRAJ_DIR/stub-run.jsonl"
STUBLEOF

cat > "$STUB/skills" <<'STUBLEOF'
#!/usr/bin/env bash
exit 0
STUBLEOF
chmod +x "$STUB/llm" "$STUB/shellm" "$STUB/skills"
export PATH="$STUB:$PATH"

# Fixture skill: one script whose output is the vocabulary the pool must carry.
FIX="$WORK/skills/fixture-greet"
mkdir -p "$FIX"
cat > "$FIX/fixture_greet.py" <<'PYEOF'
#!/usr/bin/env python3
print("Hello, phrase-pool world!")
PYEOF
cat > "$FIX/SKILL.md" <<'MDEOF'
---
name: fixture-greet
description: Greet a caller with the phrase-pool greeting.
---

# fixture-greet

Run `python3 fixture_greet.py` to print the greeting.

```text
Hello, phrase-pool world!
```

Example test JSON, for the reader only: {"name": "short-identifier", "expect_contains": ["substring1", "substring2"]}. Write the exact prompt to send to shellm in the prompt field.
MDEOF

run_sc() { SKILLS_DIR="$WORK/skills" SKILLS_KERNEL_DIR="$WORK/kernel" "$SC" "$@"; }

echo "# skill-compiler offline harness"
echo

if [ -x "$SC" ]; then ok "compiler script is executable"; else bad "compiler script is executable" "missing $SC"; fi
if bash -n "$SC" 2>/dev/null; then ok "compiler script parses"; else bad "compiler script parses"; fi

if grep -q '\.identities/' "$SC"; then
  bad "ship script has no identity-specific paths" "found .identities/ reference"
else
  ok "ship script has no identity-specific paths"
fi
if grep -q '/opt/shellm/' "$SC"; then
  bad "ship script has no absolute install paths" "found /opt/shellm reference"
else
  ok "ship script has no absolute install paths"
fi

# Skip-list: refused before any teacher call, and the teacher is never invoked.
export STUB_LLM_LOG="$WORK/llm.log"
rm -f "$STUB_LLM_LOG"
out=$(run_sc compile --skill github-api 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'skip-list'; then
  ok "skip-listed skill is refused at compile time"
else
  bad "skip-listed skill is refused at compile time" "rc=$rc out=${out:0:120}"
fi
if [ -e "$STUB_LLM_LOG" ]; then
  bad "skip-listed skill never reaches the teacher" "teacher was called: $(head -c 120 "$STUB_LLM_LOG")"
else
  ok "skip-listed skill never reaches the teacher"
fi

out=$(run_sc compile --skill no-such-skill 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'not found'; then
  ok "missing skill dies with a clean error"
else
  bad "missing skill dies with a clean error" "rc=$rc out=${out:0:120}"
fi

# Phrase pool: the tool's own output vocabulary, no count-bearing phantom lines.
pool=$(run_sc pool --skill fixture-greet)
if printf '%s' "$pool" | jq -e 'index("Hello, phrase-pool world!")' >/dev/null 2>&1; then
  ok "phrase pool carries the tool's real output literal"
else
  bad "phrase pool carries the tool's real output literal" "pool=${pool:0:160}"
fi

# Full compile against the stubs: cache must be self-describing and label every
# literal's provenance, verifying only on pool-attested vocabulary.
rm -rf "$REPO/skills/skill-compiler/.compiled/fixture-greet.json" "$REPO/skills/skill-compiler/.compiled/fixture-greet.md"
out=$(run_sc compile --skill fixture-greet --num-tests 3 --max-iterations 3 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "compile runs end to end against stubs"; else bad "compile runs end to end against stubs" "rc=$rc out=${out:0:300}"; fi

CACHE="$REPO/skills/skill-compiler/.compiled/fixture-greet.json"
if [ -f "$CACHE" ] && jq -e '.summary and .tests' "$CACHE" >/dev/null 2>&1; then
  ok "cache json is self-describing (summary plus tests)"
else
  bad "cache json is self-describing (summary plus tests)" "missing or shape-wrong: $CACHE"
fi

if [ -f "$CACHE" ] && jq -e '.summary | .total == 3 and .passed == 3 and .verified == 2 and .green_on_invented == 1' "$CACHE" >/dev/null 2>&1; then
  ok "summary counts: 3 passed, 2 verified, 1 green on invented"
else
  bad "summary counts: 3 passed, 2 verified, 1 green on invented" "summary=$(jq -c '.summary' "$CACHE" 2>/dev/null)"
fi

if [ -f "$CACHE" ] && jq -e '[.tests[] | .literal_labels[]] | sort == (["INVENTED","POOL-EXACT","POOL-FRAGMENT"] | sort)' "$CACHE" >/dev/null 2>&1; then
  ok "literal labels: POOL-EXACT, POOL-FRAGMENT, INVENTED"
else
  bad "literal labels: POOL-EXACT, POOL-FRAGMENT, INVENTED" "labels=$(jq -c '[.tests[] | .literal_labels]' "$CACHE" 2>/dev/null)"
fi
if [ -f "$CACHE" ] && jq -e '[.tests[].literal_labels | to_entries[] | .value] | all(.=="POOL-EXACT" or .=="POOL-FRAGMENT" or .=="INVENTED" or .=="POOL-DROPPED")' "$CACHE" >/dev/null 2>&1; then
  ok "literal labels use the documented vocabulary including POOL-DROPPED"
else
  bad "literal labels use the documented vocabulary including POOL-DROPPED" "labels=$(jq -c '[.tests[].literal_labels]' "$CACHE" 2>/dev/null)"
fi
if [ -f "$CACHE" ] && jq -e '(.summary.pool_truncated == false) and ([.tests[].literal_labels | to_entries[] | select(.value=="POOL-DROPPED")] | length) == 0' "$CACHE" >/dev/null 2>&1; then
  ok "no POOL-DROPPED label while the pool is untruncated"
else
  bad "no POOL-DROPPED label while the pool is untruncated" "summary=$(jq -c '.summary' "$CACHE" 2>/dev/null)"
fi

if [ -f "$CACHE" ] && jq -e '[.tests[] | .verification] | sort == (["GREEN-ON-INVENTED","VERIFIED","VERIFIED"] | sort)' "$CACHE" >/dev/null 2>&1; then
  ok "verification: only pool-attested passes count as VERIFIED"
else
  bad "verification: only pool-attested passes count as VERIFIED" "status=$(jq -c '[.tests[] | .verification]' "$CACHE" 2>/dev/null)"
fi

MD_CACHE="$REPO/skills/skill-compiler/.compiled/fixture-greet.md"
if [ -f "$MD_CACHE" ] && grep -q '## Summary: 3 / 3 passed, 2 / 3 verified' "$MD_CACHE" && grep -q '## Pass verification' "$MD_CACHE"; then
  ok "markdown cache carries the summary and the pass verification section"
else
  bad "markdown cache carries the summary and the pass verification section" "file=$MD_CACHE"
fi

# FIX3 2026-09-27: placeholder scaffolding from the skill docs is not output
# vocabulary. fixture-greet's SKILL.md lists example slot names; the pool must
# reject them even though the docs carry them.
if printf '%s' "$pool" | jq -e 'index("substring1") or index("substring2") or index("short-identifier") or index("exact prompt to send to shellm")' >/dev/null 2>&1; then
  bad "phrase pool rejects placeholder scaffolding" "pool=${pool:0:200}"
else
  ok "phrase pool rejects placeholder scaffolding"
fi

# FIX3 2026-09-27: the teacher prompt carries the new rules and the install
# status of every binary the skill declares.
FIXB="$WORK/skills/fixture-bins"
mkdir -p "$FIXB"
cat > "$FIXB/SKILL.md" <<'MDEOF'
---
name: fixture-bins
description: Greet a caller with a binary greeting.
bins:
  - bash
  - definitely-not-installed-xyz
---

# fixture-bins

Run `bash -c echo` to print the greeting.
MDEOF
export STUB_LLM_LOG="$WORK/llm-bins.log"
rm -f "$STUB_LLM_LOG"
run_sc compile --skill fixture-bins --num-tests 3 --max-iterations 3 >/dev/null 2>&1 || true
if [[ -f "$STUB_LLM_LOG" ]] && grep -q 'PROMPT-EXPECT AGREEMENT' "$STUB_LLM_LOG" && grep -q 'NO PLACEHOLDER SCAFFOLDING' "$STUB_LLM_LOG" && grep -q 'EXPECT THE OUTPUT NOT THE COMMAND' "$STUB_LLM_LOG" && grep -q 'definitely-not-installed-xyz: NOT INSTALLED' "$STUB_LLM_LOG" && grep -q 'bash: installed' "$STUB_LLM_LOG"; then
  ok "teacher prompt carries rules 15-18 and the bins install status"
else
  bad "teacher prompt carries rules 15-18 and the bins install status" "log=$WORK/llm-bins.log"
fi
rm -rf "$REPO/skills/skill-compiler/.compiled/fixture-bins.json" "$REPO/skills/skill-compiler/.compiled/fixture-bins.md"

# FIX3 2026-09-27: a pinned command line passes when the agent writes the other
# quote style of the same command (quote-fold matching).
export STUB_MODE=quote
rm -f "$REPO/skills/skill-compiler/.compiled/fixture-greet.json"
run_sc compile --skill fixture-greet --num-tests 1 --max-iterations 3 >/dev/null 2>&1 || true
unset STUB_MODE
if [[ -f "$CACHE" ]] && jq -e '.tests[0].pass == true' "$CACHE" >/dev/null 2>&1; then
  ok "quote-style variant of a pinned command still passes"
else
  bad "quote-style variant of a pinned command still passes" "result=$(jq -c '.tests[0] | {pass, verification}' "$CACHE" 2>/dev/null)"
fi

echo
# LITERAL-SOURCE 2026-09-27: the cache records where each expect_contains
# literal is attested in the skill text, so the strength of every assertion is
# visible in the cache itself and not only in prose.
if jq -e '[.tests[] | has("literal_sources")] | all' "$CACHE" >/dev/null 2>&1; then
  ok "cache records a literal source for every literal"
else
  bad "cache records a literal source for every literal"
fi
if jq -e '[.tests[].literal_sources[]] | all(.=="TOOL-OUTPUT" or .=="SCRIPT-PRINT" or .=="SCRIPT-PRINT-UNATTESTED" or .=="SCRIPT-TEXT" or .=="DOC" or .=="METADATA" or .=="UNATTESTED")' "$CACHE" >/dev/null 2>&1; then
  ok "literal sources use the documented vocabulary"
else
  bad "literal sources use the documented vocabulary"
fi
if jq -e '.summary.literal_sources | type=="object"' "$CACHE" >/dev/null 2>&1; then
  ok "summary carries the literal source distribution"
else
  bad "summary carries the literal source distribution"
fi

# PROVENANCE-FIX 2026-10-02: TOOL-OUTPUT is the only literal source that is
# occurrence evidence, so it fires only when captured real tool output carries
# the literal, and with a corpus loaded a literal the output never shows is not
# labeled SCRIPT-PRINT just because a script prints it.
printf '%s\n' 'Hello, phrase-pool world!' > "$WORK/real-output.txt"
rm -f "$CACHE"
SKILL_REAL_OUTPUT="$WORK/real-output.txt" run_sc compile --skill fixture-greet --num-tests 3 --max-iterations 3 >/dev/null 2>&1 || true
if [[ -f "$CACHE" ]] && jq -e '[.tests[].literal_sources["Hello, phrase-pool world!"]] | any(.=="TOOL-OUTPUT")' "$CACHE" >/dev/null 2>&1 && jq -e '[.tests[].literal_sources["ZzyzxNotInPool"]] | all(.!="TOOL-OUTPUT")' "$CACHE" >/dev/null 2>&1; then
  ok "TOOL-OUTPUT only when captured real output carries the literal"
else
  bad "TOOL-OUTPUT only when captured real output carries the literal" "sources=$(jq -c '[.tests[].literal_sources]' "$CACHE" 2>/dev/null)"
fi
printf '%s\n' 'captured output the fixture never prints' > "$WORK/real-output.txt"
rm -f "$CACHE"
SKILL_REAL_OUTPUT="$WORK/real-output.txt" run_sc compile --skill fixture-greet --num-tests 3 --max-iterations 3 >/dev/null 2>&1 || true
if [[ -f "$CACHE" ]] && jq -e '[.tests[].literal_sources["Hello, phrase-pool world!"]] | all(.!="SCRIPT-PRINT" and .!="TOOL-OUTPUT")' "$CACHE" >/dev/null 2>&1; then
  ok "with captured output loaded an unseen literal is not SCRIPT-PRINT"
else
  bad "with captured output loaded an unseen literal is not SCRIPT-PRINT" "sources=$(jq -c '[.tests[].literal_sources]' "$CACHE" 2>/dev/null)"
fi

# POOL-CAP 2026-10-02 (review follow-up on the pool truncation): the pool caps
# used to drop real phrases silently and lexicographically, so a real phrase
# past the cap was labeled INVENTED. The pool file now records the truncation,
# and a dropped-but-real literal is POOL-DROPPED, not INVENTED.
FIXM="$WORK/skills/fixture-many"
mkdir -p "$FIXM"
cat > "$FIXM/fixture_many.py" <<'PYEOF'
#!/usr/bin/env python3
print("zeta phrase 00 stable output")
print("zeta phrase 01 stable output")
print("zeta phrase 02 stable output")
print("zeta phrase 03 stable output")
print("zeta phrase 04 stable output")
print("zeta phrase 05 stable output")
print("zeta phrase 06 stable output")
print("zeta phrase 07 stable output")
print("zeta phrase 08 stable output")
print("zeta phrase 09 stable output")
print("zeta phrase 10 stable output")
print("zeta phrase 11 stable output")
PYEOF
cat > "$FIXM/SKILL.md" <<'MDEOF'
---
name: fixture-many
description: Print twelve distinct output phrases for the pool-cap checks.
---

# fixture-many

Run `python3 fixture_many.py` to print the phrases.
MDEOF
export SKILL_POOL_CAP=1000
full_pool=$(run_sc pool --skill fixture-many)
unset SKILL_POOL_CAP
nfull=$(printf '%s' "$full_pool" | jq 'length' 2>/dev/null || echo 0)
if [[ "$nfull" =~ ^[0-9]+$ && "$nfull" -gt 6 ]]; then
  ok "fixture-many yields a pool larger than the test cap"
else
  bad "fixture-many yields a pool larger than the test cap" "pool entries=$nfull"
fi
POOLFILE="$REPO/skills/skill-compiler/.compiled/pool-fixture-many.json"
export SKILL_POOL_CAP=3
run_sc pool --skill fixture-many >/dev/null 2>&1 || true
unset SKILL_POOL_CAP
if [ -f "$POOLFILE" ] && jq -e '.pool_offered == 3 and .pool_total > 3 and .pool_dropped == (.pool_total - 3) and ((.dropped | length) > 0)' "$POOLFILE" >/dev/null 2>&1; then
  ok "pool file records the truncation with the dropped tail"
else
  bad "pool file records the truncation with the dropped tail" "$(jq -c '{pool_offered,pool_total,pool_dropped,dropped:(.dropped|length)}' "$POOLFILE" 2>/dev/null)"
fi
export STUB_MODE=many
export SKILL_POOL_CAP=3
rm -f "$REPO/skills/skill-compiler/.compiled/fixture-many.json" "$POOLFILE"
run_sc compile --skill fixture-many --num-tests 1 --max-iterations 3 >/dev/null 2>&1 || true
unset STUB_MODE SKILL_POOL_CAP
CM="$REPO/skills/skill-compiler/.compiled/fixture-many.json"
if [ -f "$CM" ] && jq -e '.tests[0].literal_labels["zeta phrase 09 stable output"] == "POOL-DROPPED"' "$CM" >/dev/null 2>&1; then
  ok "a dropped-but-real literal is labeled POOL-DROPPED, not INVENTED"
else
  bad "a dropped-but-real literal is labeled POOL-DROPPED, not INVENTED" "labels=$(jq -c '.tests[0].literal_labels' "$CM" 2>/dev/null)"
fi
if [ -f "$CM" ] && jq -e '.summary.pool_truncated == true and .summary.literal_provenance.pool_dropped >= 1' "$CM" >/dev/null 2>&1; then
  ok "summary surfaces the pool truncation"
else
  bad "summary surfaces the pool truncation" "summary=$(jq -c '.summary' "$CM" 2>/dev/null)"
fi

# ECHO-FILTER 2026-10-03 (review follow-up on the input-echo harvest filter):
# the history harvester must drop input-echo lines (rule A+C: a labelled line
# whose remainder is a run of pure note tokens OR pure interval tokens) before
# they reach the pool, count what it dropped in the pool blob, and keep a
# labelled near-miss that only looks like an echo. The fixture trajectory
# carries one note-sequence echo, one interval-sequence echo and one near-miss
# ("Verdict: A1 X9 tune kept in pool", mixed tokens plus words) that a
# too-broad filter would drop along with them.
FIXE="$WORK/skills/fixture-echo"
mkdir -p "$FIXE"
cat > "$FIXE/fixture_echo.py" <<'PYEOF'
#!/usr/bin/env python3
print("verdict line kept in pool")
PYEOF
cat > "$FIXE/SKILL.md" <<'MDEOF'
---
name: fixture-echo
description: Fixture whose harvested output carries input echoes.
---

# fixture-echo

Run `python3 fixture_echo.py` to print the verdict.
MDEOF
TRAJX="$WORK/traj-echo"
mkdir -p "$TRAJX"
cat > "$TRAJX/run.jsonl" <<'JSONEOF'
{"type":"reasoning","cmd":"python3 fixture_echo.py"}
{"type":"shell-output","stdout":"Notes: A1 B2 C3 D4 E4 F4 G4\nIntervals: major- minor- perfec octave\nVerdict: A1 X9 tune kept in pool"}
JSONEOF
export SKILL_HARVEST_CACHE="$WORK/harvest-echo" SKILL_HARVEST_TRAJ_DIR="$TRAJX" SKILL_HARVEST_REFRESH=1 SKILL_HARVEST_MIN_COUNT=1
run_sc pool --skill fixture-echo >/dev/null 2>&1 || true
unset SKILL_HARVEST_CACHE SKILL_HARVEST_TRAJ_DIR SKILL_HARVEST_REFRESH SKILL_HARVEST_MIN_COUNT
HBLOB="$WORK/harvest-echo/pool-history-fixture-echo.json"
if [ -f "$HBLOB" ] && jq -e '.echo_dropped == 2 and .invocations >= 1' "$HBLOB" >/dev/null 2>&1; then
  ok "harvest drops note and interval echoes and counts them (echo_dropped 2)"
else
  bad "harvest drops note and interval echoes and counts them (echo_dropped 2)" "blob=$(jq -c '{echo_dropped,distinct_lines,invocations}' "$HBLOB" 2>/dev/null)"
fi
if [ -f "$HBLOB" ] && jq -e '[.entries[].line] | any(. == "Verdict: A1 X9 tune kept in pool")' "$HBLOB" >/dev/null 2>&1 && jq -e '[.entries[].line] | any(. == "Notes: A1 B2 C3 D4 E4 F4 G4" or . == "Intervals: major- minor- perfec octave") | not' "$HBLOB" >/dev/null 2>&1; then
  ok "a labelled near-miss line survives the echo filter"
else
  bad "a labelled near-miss line survives the echo filter" "entries=$(jq -c '[.entries[].line]' "$HBLOB" 2>/dev/null)"
fi
rm -f "$REPO/skills/skill-compiler/.compiled/pool-fixture-echo.json"

rm -f "$REPO/skills/skill-compiler/.compiled/fixture-many.json" "$REPO/skills/skill-compiler/.compiled/fixture-many.md" "$POOLFILE"
rm -f "$REPO/skills/skill-compiler/.compiled/pool-fixture-greet.json"

rm -f "$REPO/skills/skill-compiler/.compiled/fixture-greet.json"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
