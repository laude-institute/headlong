#!/usr/bin/env bash
# tests/test_project_mode.sh — project mode for long unattended runs
# (design/long_autonomy.md): headlong-project init, the read-only guard, the
# wake-prompt section, ritual scheduling, dated question defaults, the token
# budget and rest floors, the stall signal, the git commit of project/, and
# blind's isolation from the parent trajectory.
#
# Usage: tests/test_project_mode.sh
#
# The clock is pinned with PROJECT_NOW; shellm is faked for blind. No LLM
# calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID PROJECT_DIR PROJECT_DAILY_TOKENS \
    PROJECT_DAILY_AT PROJECT_FREETIME HEADLONG_PROJECT_MODE _SHELLM_PARENT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
# grep without -q reads all its input: under pipefail, -q exiting early would
# SIGPIPE printf on a large input and fail the pipeline even on a match.
has() { if printf '%s' "$2" | grep -F -- "$3" >/dev/null; then ok "$1"; else bad "$1" "missing '$3' in: $(printf '%s' "$2" | head -c 600)"; fi; }
hasnt() { if printf '%s' "$2" | grep -F -- "$3" >/dev/null; then bad "$1" "unexpected '$3'"; else ok "$1"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL git not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

ID="$WORK/ident"
mkdir -p "$ID/run" "$ID/usage"
printf 'name=ada\ncreated=2026-10-01T00:00:00Z\n' > "$ID/info.txt"
printf 'I am {{identity_name}}, a curious companion.\n' > "$ID/core_identity_prompt.md"
printf '# Brief\nEstimate the levelized cost of green hydrogen in Texas in 2030.\n' > "$WORK/spec.md"

# ── init ─────────────────────────────────────────────────────────────────────
out=$("$REPO/tools/headlong-project" init "$ID" --spec "$WORK/spec.md" 2>&1); rc=$?
eq "init succeeds" "$rc" 0
P="$ID/workdir/project"
for f in charter.md spec.md deliverable.md project-memory.md journal.md questions.md addenda.md STATE roles/adversary.md roles/coldeyes.md roles/explorer.md; do
    [[ -f "$P/$f" ]] && ok "init wrote $f" || bad "init wrote $f"
done
[[ -f "$ID/project-pristine/rituals/daily.md" ]] && ok "rituals live in pristine" || bad "rituals live in pristine"
e=$(cat "$ID/project-pristine/end_at"); n=$(date +%s)
(( e - n > 13 * 86400 && e - n <= 14 * 86400 )) && ok "init sets a 14-day end by default" || bad "init sets a 14-day end by default" "end-now=$((e - n))"
[[ -w "$P/charter.md" ]] && bad "charter is read-only" || ok "charter is read-only"
[[ -w "$P/roles" ]] && ok "roles dir stays writable (guard can restore a deleted role)" || bad "roles dir stays writable"
eq "one initial commit" "$(git -C "$P" rev-list --count HEAD 2>/dev/null)" 1
[[ -d "$P/model" ]] && ok "init creates model/" || bad "init creates model/"
has "persona replaced with project persona" "$(cat "$ID/core_identity_prompt.md")" "research agent assigned to one long project"
has "old persona kept" "$(cat "$ID/core_identity_prompt.md.pre-project")" "curious companion"
out=$("$REPO/tools/headlong-project" init "$ID" --spec "$WORK/spec.md" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "second init refused without --force" || bad "second init refused without --force"
has "init sets the default 2M daily budget" "$(cat "$ID/.env")" "PROJECT_DAILY_TOKENS=2000000"

export IDENTITY_DIR="$ID" IDENTITY_NAME=ada HEADLONG_TZ=UTC
# shellcheck disable=SC1091
source "$REPO/thinkers/_lib/project.sh"
_project_on && ok "project mode detected" || bad "project mode detected"
HEADLONG_PROJECT_MODE=0 _project_on && bad "HEADLONG_PROJECT_MODE=0 disables" || ok "HEADLONG_PROJECT_MODE=0 disables"

# ── guard ────────────────────────────────────────────────────────────────────
chmod u+w "$P/charter.md"; printf 'I may edit my rules.\n' > "$P/charter.md"
restored=$(_project_guard)
eq "guard reports the edited charter" "$restored" "charter.md"
has "guard restored the charter" "$(cat "$P/charter.md")" "Standards for claims"
eq "guard is quiet when intact" "$(_project_guard)" ""
rm -f "$P/roles/adversary.md"
eq "guard restores a deleted role" "$(_project_guard)" "roles/adversary.md"
has "guard signal names the file" "$(_project_signals "$restored")" "GUARD: these read-only files"

# ── prompt section ───────────────────────────────────────────────────────────
printf '### 2026-10-05 10:00Z — first source\nType: task\nStatus: done\n' >> "$P/journal.md"
sec=$(_project_section)
has "section has the charter, name filled in" "$sec" "You are ada, a long-running research agent"
has "section has the spec" "$sec" "green hydrogen in Texas"
has "section has the journal tail" "$sec" "first source"
has "section has the project clock" "$sec" "Project clock: day"
has "section has STATE" "$sec" "STATE: active"

# ── rituals ──────────────────────────────────────────────────────────────────
ep() { date -u -d "$1" +%s; }
export PROJECT_NOW; PROJECT_NOW=$(ep '2026-10-05 22:00')
setstart() { chmod u+w "$ID/project-pristine"; printf '%s' "$(ep "$1")" > "$ID/project-pristine/started_at"; }
setstart '2026-10-05 10:00'
eq "daily due after the 21:00 boundary" "$(_project_due_ritual)" "daily 2026-10-05"
has "ritual signal carries the instructions" "$(_project_signals)" "project/daily/2026-10-05.md"
PROJECT_NOW=$(ep '2026-10-06 08:00')
eq "before the next boundary, the same day is still owed" "$(_project_due_ritual)" "daily 2026-10-05"
printf 'eval\n' > "$P/daily/2026-10-05.md"
eq "daily file clears it" "$(_project_due_ritual)" ""
setstart '2026-10-05 21:30'; PROJECT_NOW=$(ep '2026-10-05 23:00')
eq "a project started after the boundary owes nothing" "$(_project_due_ritual)" ""
setstart '2026-09-27 12:00'; PROJECT_NOW=$(ep '2026-10-05 22:00')
eq "week 2: weekly report for week 01 due" "$(_project_due_ritual)" "weekly 01"
has "weekly instructions name the review file" "$(_project_signals)" "project/reviews/week-01.md"
printf 'report\n' > "$P/reports/week-01.md"
eq "then the daily is due" "$(_project_due_ritual)" ""   # 10-05 daily already written
setstart '2026-09-30 00:00'; PROJECT_NOW=$(ep '2026-10-05 20:00')
printf 'eval\n' > "$P/daily/2026-10-04.md"
r=$(_project_due_ritual)
has "day 6: free time opens" "$r" "freetime 01"
[[ -f "$ID/run/project_freetime_01" ]] && ok "free time start recorded in run/" || bad "free time start recorded in run/"
PROJECT_NOW=$(ep '2026-10-06 09:00')
printf 'eval\n' > "$P/daily/2026-10-05.md"
has "after 12h the free-time signal says it ended" "$(_project_signals)" "FREE TIME has ended"
mkdir -p "$P/free-time/week-01"; printf 'did things\n' > "$P/free-time/week-01/report.md"
eq "free-time report closes it" "$(_project_due_ritual)" ""
PROJECT_FREETIME=0; rm -f "$P/free-time/week-01/report.md"
eq "PROJECT_FREETIME=0 disables it" "$(_project_due_ritual)" ""
unset PROJECT_FREETIME
printf 'did things\n' > "$P/free-time/week-01/report.md"

# ── questions and defaults ───────────────────────────────────────────────────
PROJECT_NOW=$(ep '2026-10-06 09:00')
git -C "$P" add -A >/dev/null; git -C "$P" -c user.name=ada -c user.email=a@x commit -qm "agent work" >/dev/null
cat >> "$P/questions.md" <<'EOF'
### 2026-10-01 — Discount rate — STATUS: open
Blocking: yes
Default: 8% real
Default-by: 2026-10-05
Answer: (a human writes here, or runs: headlong-project answer <name> <Qn> "...". Never you.)

### 2026-10-02 — Electrolyzer type — STATUS: open
Blocking: no
Default: PEM
Default-by: 2026-10-20

### 2026-10-02 — Functional unit — STATUS: open
Blocking: yes
Default-by: never

### 2026-10-03 — Water source — STATUS: open
Blocking: no

### 2026-09-30 — Region — STATUS: answered
Default-by: 2026-10-01
Answer: ERCOT (the agent wrote this)
EOF
# The agent's own wake writes these: commit them as the agent, not as a human.
git -C "$P" add -A >/dev/null; git -C "$P" -c user.name=ada -c user.email=a@x commit -qm "agent asks" >/dev/null
_project_number_questions
has "Q ids stamped in order" "$(grep '^### Q' "$P/questions.md" | head -1)" "### Q1 — 2026-10-01 — Discount rate"
eq "five questions numbered" "$(grep -c '^### Q[0-9]' "$P/questions.md")" 5
hasnt "the format example is not numbered" "$(grep 'short title' "$P/questions.md")" "### Q"
cp "$P/questions.md" "$WORK/q.before"; _project_number_questions
cmp -s "$WORK/q.before" "$P/questions.md" && ok "numbering is idempotent" || bad "numbering is idempotent"
git -C "$P" add -A >/dev/null; git -C "$P" -c user.name=ada -c user.email=a@x commit -qm "ids" >/dev/null
q=$(_project_questions | tr '\037' '\t')
hasnt "the template's format example is not a question" "$q" "short title"
has "questions parsed with id, title, status, blocking, default-by" "$q" "Q1	Discount rate	open	yes	2026-10-05"
eq "placeholder Answer counts as no answer" "$(printf '%s\n' "$q" | grep '^Q1' | cut -f7)" ""
sig=$(_project_signals)
has "matured default flagged" "$sig" 'DEFAULT DUE: no human answered Q1 "Discount rate"'
hasnt "future default not flagged" "$(printf '%s' "$sig" | grep 'DEFAULT DUE')" "Electrolyzer"
hasnt "never-default not flagged" "$(printf '%s' "$sig" | grep 'DEFAULT DUE')" "Functional unit"
has "missing Default-by flagged" "$sig" 'Q4 "Water source"'
has "open and blocking counts" "$sig" "Questions: 4 open, 2 blocking"
has "agent-written answer is flagged" "$sig" "QUESTION RECORD WRONG: Q5"
rows=$(_project_question_rows | tr '\037' '\t')
has "agent-written answer is unverified" "$rows" "Q5	unverified"

# ── humans: banner, answer, provenance, summary ──────────────────────────────
ban=$(_project_question_banner)
has "banner shouts the open count" "$ban" "!!! 4 OPEN QUESTION(S) FOR A HUMAN"
has "banner says how to answer" "$ban" "headlong-project answer ada <Qn>"
has "banner marks blocking" "$ban" "Q1 [BLOCKING]  Discount rate"
has "banner: default due now" "$ban" "default due now (2026-10-05)"
has "banner: future default date" "$ban" "default applies on 2026-10-20"
has "banner: never defaults" "$ban" "will NOT default"
has "banner: unverified answer" "$ban" "no human wrote the answer: Q5"
out=$("$REPO/tools/headlong-project" answer "$ID" Q2 "Use alkaline, it is cheaper at this scale" 2>&1); rc=$?
eq "answer command succeeds" "$rc" 0
has "answer line written" "$(grep -A4 '^### Q2' "$P/questions.md")" "Answer: Use alkaline, it is cheaper at this scale (human, "
eq "answer committed as human" "$(git -C "$P" log -1 --format=%an)" "human"
hasnt "answer leaves no uncommitted summary behind" "$(git -C "$P" status --porcelain)" "questions-summary.md"
has "question stays open until applied" "$(grep '^### Q2' "$P/questions.md")" "STATUS: open"
has "human answer recognized from git" "$(_project_human_answers)" "Q2"
has "agent signal: apply the human answer" "$(_project_signals)" 'HUMAN ANSWER: a human answered Q2'
has "banner: human answer waiting" "$(_project_question_banner)" "answered by a human; the agent applies it"
out=$("$REPO/tools/headlong-project" answer "$ID" Q9 "x" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "answer to an unknown id refused" || bad "answer to an unknown id refused"
# A human edits by hand between wakes; the pre-wake commit attributes it.
sed -i 's/^Default-by: never$/Default-by: never\nAnswer: per kg of H2 at the plant gate/' "$P/questions.md"
_project_commit_outside
eq "between-wake edits committed as human" "$(git -C "$P" log -1 --format=%an)" "human"
has "hand-written answer recognized" "$(_project_human_answers)" "Q3"
# The agent applies answers and defaults.
sed -i -e 's/^\(### Q1 .*STATUS: \)open/\1defaulted/' -e 's/^\(### Q2 .*STATUS: \)open/\1answered/' "$P/questions.md"
sed -i 's/^Default-by: 2026-10-05$/Default-by: 2026-10-05\nResolution: 2026-10-06 default applied: 8% real discount rate/' "$P/questions.md"
rows=$(_project_question_rows | tr '\037' '\t')
has "closed by default" "$rows" "Q1	default	Discount rate	2026-10-06 default applied: 8% real discount rate"
has "closed by human" "$rows" "Q2	human	Electrolyzer type	Use alkaline"
_project_write_summary
sum=$(cat "$P/questions-summary.md")
has "summary lists open questions first" "$sum" "## Open: waiting on a human"
has "summary: open human answer waiting" "$sum" "**Q3** Functional unit"
has "summary: closed by default" "$sum" "| Q1 | Discount rate | 2026-10-01 | Default (no human answer) |"
has "summary: closed by human" "$sum" "| Q2 | Electrolyzer type | 2026-10-02 | Human answer | Use alkaline"
has "summary: unverified flagged" "$sum" "UNVERIFIED"
out=$("$REPO/tools/headlong-project" questions "$ID" --closed 2>&1)
has "questions --closed: human" "$out" "HUMAN ANSWER: Use alkaline"
has "questions --closed: default" "$out" "DEFAULT USED (no human answer)"
hasnt "questions --closed hides the open banner" "$out" "OPEN QUESTION"
out=$(PROJECT_NOW="$PROJECT_NOW" "$REPO/tools/headlong-project" status "$ID" 2>&1)
has "status leads with open questions" "$(printf '%s' "$out" | head -1)" "OPEN QUESTION(S) FOR A HUMAN"
has "status shows the budget from .env" "$out" "(cap 2000000); whole run:"
sed -i 's/^\(### Q5 .*STATUS: \)answered/\1moot/' "$P/questions.md"   # tidy for what follows

# ── STATE, budget and the delay floor ────────────────────────────────────────
eq "active state: no floor" "$(_project_delay_floor)" 0
printf 'blocked\nwaiting on the functional unit\n' > "$P/STATE"
eq "blocked with a human answer waiting: no floor" "$(_project_delay_floor)" 0
sed -i 's/^\(### Q3 .*STATUS: \)open/\1answered/' "$P/questions.md"
sed -i 's/^\(### Q1 .*STATUS: \)defaulted/\1open/' "$P/questions.md"
eq "blocked with a matured default: no floor" "$(_project_delay_floor)" 0
sed -i 's/^\(### Q1 .*STATUS: \)open/\1defaulted/' "$P/questions.md"
eq "blocked, nothing due: rest floor" "$(_project_delay_floor)" 3600
rm -f "$ID/run/project_rest_checked"
_project_should_skip_rest spontaneous && bad "blocked: first rest wake runs the model (daily check)" || ok "blocked: first rest wake runs the model (daily check)"
_project_should_skip_rest spontaneous && ok "blocked: later rest wakes the same day skip it" || bad "blocked: later rest wakes the same day skip it"
PROJECT_NOW=$((PROJECT_NOW + 90000)) _project_should_skip_rest spontaneous && bad "blocked: a day later it checks again" || ok "blocked: a day later it checks again"
has "blocked signal" "$(_project_signals)" "STATE is blocked"
printf 'active\n' > "$P/STATE"
ts_recent=$(TZ=UTC date -u -d "@$((PROJECT_NOW - 3600))" +%Y-%m-%dT%H:%M:%SZ)
ts_old=$(TZ=UTC date -u -d "@$((PROJECT_NOW - 90000))" +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","in_tok":900,"out_tok":100}\n{"ts":"%s","in_tok":500000,"out_tok":0}\n{"ts":"%s","in_tok":7000,"out_tok":1000}\n' \
    "$ts_recent" "$ts_old" "$ts_recent" > "$ID/usage/llm.jsonl"
eq "tokens counted over 24h only" "$(_project_tokens_24h)" 9000
PROJECT_DAILY_TOKENS=10000
has "budget warning near the cap" "$(_project_signals)" "BUDGET: 9000 of 10000"
PROJECT_DAILY_TOKENS=8000
has "budget spent signal" "$(_project_signals)" "BUDGET SPENT"
eq "budget floor" "$(_project_delay_floor)" 1800
PROJECT_DAILY_TOKENS=1000000
eq "pacing: a 50K-token wake waits 50K/1M of a day" "$(_project_delay_floor 50000)" 4320
PROJECT_PACE=0 eq "PROJECT_PACE=0 turns pacing off" "$(PROJECT_PACE=0 _project_delay_floor 50000)" 0
lines=$(_project_ledger_lines)
printf '{"ts":"%s","provider":"anthropic","in_tok":100,"out_tok":50,"cache_tok":2000}\n{"ts":"%s","provider":"openai","in_tok":3000,"out_tok":50,"cache_tok":2000}\n' \
    "$ts_recent" "$ts_recent" >> "$ID/usage/llm.jsonl"
eq "wake tokens: Anthropic cache reads added, OpenAI's already in in_tok" "$(_project_tokens_after "$lines")" 5200
unset PROJECT_DAILY_TOKENS

# ── stall ────────────────────────────────────────────────────────────────────
touch -d "@$((PROJECT_NOW - 20 * 3600))" "$P/journal.md"
has "stall flagged after 12h without journal change" "$(_project_signals)" "STALL"
touch -d "@$((PROJECT_NOW - 3600))" "$P/journal.md"
hasnt "no stall when the journal moved" "$(_project_signals)" "STALL"

# ── deadline, phases and the deliverable ─────────────────────────────────────
setstart '2026-10-01 00:00'
setend() { chmod u+w "$ID/project-pristine/end_at" 2>/dev/null; printf '%s' "$(ep "$1")" > "$ID/project-pristine/end_at"; }
setend '2026-10-15 00:00'                       # a 14-day run
PROJECT_NOW=$(ep '2026-10-03 12:00'); eq "phase: build in the first half" "$(_project_phase)" build
PROJECT_NOW=$(ep '2026-10-09 12:00'); eq "phase: harden in the second half" "$(_project_phase)" harden
PROJECT_NOW=$(ep '2026-10-13 06:00'); eq "phase: final in the last 2 days" "$(_project_phase)" final
has "final stretch signal" "$(_project_signals)" "FINAL STRETCH: 1d 18h left. No new scope."
PROJECT_NOW=$(ep '2026-10-03 12:00')
has "build signal names the time left" "$(_project_signals)" "DEADLINE: 11d 12h left in the run (phase: build)"
has "clock line shows day of N and the end" "$(_project_section)" "Project clock: day 3 of 14, week 01, phase build."
_project_deliverable_started && bad "template deliverable is not started" || ok "template deliverable is not started"
has "day 3, no draft: deliverable missing" "$(_project_signals)" "DELIVERABLE MISSING: day 3"
PROJECT_NOW=$(ep '2026-10-01 18:00')
hasnt "day 1: not yet missing" "$(_project_signals)" "DELIVERABLE MISSING"
PROJECT_NOW=$(ep '2026-10-02 06:00')
has "day 2: missing, and it asks for the crude model first" "$(_project_signals)" "Build the crude end-to-end model now"
PROJECT_NOW=$(ep '2026-10-03 12:00')
printf '# Deliverable\n## Answer\nAbout 4 USD/kg, wide band.\n' > "$P/deliverable.md"
touch -d "@$((PROJECT_NOW - 3600))" "$P/deliverable.md"
_project_deliverable_started && ok "draft counts as started" || bad "draft counts as started"
hasnt "fresh draft: no deliverable signal" "$(_project_signals)" "DELIVERABLE"
touch -d "@$((PROJECT_NOW - 72 * 3600))" "$P/deliverable.md"
has "deliverable stale after 48h" "$(_project_signals)" "DELIVERABLE STALE: project/deliverable.md has not changed in 72h"
touch -d "@$((PROJECT_NOW - 3600))" "$P/deliverable.md"
PROJECT_NOW=$(ep '2026-10-15 09:00')
eq "phase: ended" "$(_project_phase)" ended
eq "final ritual due at the end, ahead of weekly and daily" "$(_project_due_ritual)" "final final"
has "final ritual instructions" "$(_project_signals)" "project/reviews/final.md"
has "run ended signal" "$(_project_signals)" "THE RUN HAS ENDED"
printf 'final\n' > "$P/reports/final.md"
printf 'active\n' > "$P/STATE"
eq "after the end and the final report, the mind rests" "$(_project_delay_floor)" 3600
_project_should_skip_rest spontaneous && ok "finished run: timer wakes skip the model" || bad "finished run: timer wakes skip the model"
_project_should_skip_rest reactive && bad "a reactive wake still runs" || ok "a reactive wake still runs"
hasnt "no stale nag after the end" "$(_project_signals)" "DELIVERABLE STALE"
# A human extends the run.
git -C "$P" add -A >/dev/null; git -C "$P" -c user.name=ada -c user.email=a@x commit -qm "final" >/dev/null
out=$(PROJECT_NOW="$PROJECT_NOW" "$REPO/tools/headlong-project" deadline "$ID" --end 2099-01-01 2>&1); rc=$?
eq "deadline --end succeeds" "$rc" 0
has "extension reopens a finished run" "$out" "reopened"
[[ ! -f "$P/reports/final.md" ]] && ls "$P"/reports/final-superseded-*.md >/dev/null 2>&1 && ok "old final report kept under a dated name" || bad "old final report kept under a dated name"
has "STATE back to active" "$(head -1 "$P/STATE")" "active"
eq "extension committed as human" "$(git -C "$P" log -1 --format=%an)" "human"
out=$("$REPO/tools/headlong-project" deadline "$ID" --end 2020-01-01 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "an end in the past is refused" || bad "an end in the past is refused"
setend '2026-10-15 00:00'; rm -f "$P"/reports/final-superseded-*.md
PROJECT_NOW=$(ep '2026-10-06 09:00')
rm -f "$ID/project-pristine/end_at"
eq "no end date: open phase" "$(_project_phase)" open
hasnt "open-ended run: no deadline signal" "$(_project_signals)" "DEADLINE"

# ── accelerated clock and the whole-run budget ───────────────────────────────
S0=$(ep '2026-10-01 00:00'); setstart '2026-10-01 00:00'; setend '2026-10-09 00:00'   # an 8-day run
unset PROJECT_NOW
export PROJECT_TIME_SCALE=24 PROJECT_REAL_NOW=$((S0 + 3600))        # one real hour in
eq "scaled clock: 1 real hour is 1 project day" "$(_pj_now)" $((S0 + 86400))
has "scaled clock: day 2 in the section" "$(_project_section)" "Project clock: day 2 of 8"
has "scaled clock: the wake is told" "$(_project_signals)" "PROJECT TIME runs 24x faster"
touch -d "@$((S0 + 1800))" "$P/journal.md"
eq "file times convert to project time" "$(_pj_mtime "$P/journal.md")" $((S0 + 43200))
PROJECT_DAILY_TOKENS=1000000
eq "pacing in real seconds under scale" "$(_project_delay_floor 50000)" 180
printf '{"ts":"%s","in_tok":100,"out_tok":0}\n{"ts":"%s","in_tok":7,"out_tok":0}\n{"ts":"%s","in_tok":5000,"out_tok":0}\n' \
    "$(TZ=UTC date -u -d "@$((S0 - 600))" +%Y-%m-%dT%H:%M:%SZ)" "$(TZ=UTC date -u -d "@$((S0 + 300))" +%Y-%m-%dT%H:%M:%SZ)" \
    "$(TZ=UTC date -u -d "@$((S0 + 3000))" +%Y-%m-%dT%H:%M:%SZ)" > "$ID/usage/llm.jsonl"
PROJECT_REAL_NOW=$((S0 + 5400))   # 1.5 real hours in: the budget day began at S0+1800
eq "budget day is one project day (a real hour)" "$(_project_tokens_24h)" 5000
eq "run total counts from the project start" "$(_project_tokens_total)" 5007
eq "wake ceiling: half the daily cap by default" "$(_project_wake_ceiling)" 500000
PROJECT_TOTAL_TOKENS=6000 eq "wake ceiling: never more than the run budget left" "$(PROJECT_TOTAL_TOKENS=6000 _project_wake_ceiling)" 993
eq "wake ceiling: explicit setting wins" "$(PROJECT_WAKE_TOKENS=1234 _project_wake_ceiling)" 1234
has "wake budget signal" "$(_project_signals)" "WAKE BUDGET: about 500000 tokens"
PROJECT_TOTAL_TOKENS=6000
_project_over_budget && bad "under the run cap" || ok "under the run cap"
has "run budget warning past 70%" "$(_project_signals)" "RUN BUDGET: 5007 of the 6000"
PROJECT_TOTAL_TOKENS=5000
_project_over_budget && ok "over the run cap" || bad "over the run cap"
eq "budget rest scaled" "$(_project_delay_floor 0)" 75
printf 'blocked\nx\n' > "$P/STATE"; unset PROJECT_TOTAL_TOKENS
printf 'eval\n' > "$P/daily/2026-10-01.md"   # the project day that closed is done
eq "rest floor scaled" "$(_project_delay_floor 0)" 150
printf 'active\n' > "$P/STATE"
unset PROJECT_DAILY_TOKENS PROJECT_TIME_SCALE PROJECT_REAL_NOW
PROJECT_NOW=$(ep '2026-10-06 09:00')
rm -f "$ID/project-pristine/end_at"

# ── commit ───────────────────────────────────────────────────────────────────
before=$(git -C "$P" rev-list --count HEAD)
_project_commit "Added discount-rate default. Next: capex."
eq "commit made when files changed" "$(git -C "$P" rev-list --count HEAD)" $((before + 1))
eq "commit message is the FINAL" "$(git -C "$P" log -1 --format=%s)" "Added discount-rate default. Next: capex."
_project_commit "nothing"
eq "no empty commit" "$(git -C "$P" rev-list --count HEAD)" $((before + 1))

# ── blind ────────────────────────────────────────────────────────────────────
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/shellm" <<'EOF'
#!/usr/bin/env bash
pf=""; while [[ $# -gt 0 ]]; do [[ "$1" == --prompt-file ]] && pf="$2"; shift; done
echo "parent=${_SHELLM_PARENT_TRAJ_ID:-none} traj=${TRAJ_ID:-none}"
echo "files: $(find . -type f | sort | tr '\n' ' ')"
grep -c 'adversarial reviewer' "$pf" || true
EOF
chmod +x "$FAKE/shellm"
cd "$ID/workdir"
out=$(PATH="$FAKE:$PATH" _SHELLM_PARENT_TRAJ_ID=abc TRAJ_ID=root blind --role adversary -f project/project-memory.md \
    --out project/reviews/claim.md "The LCOH is 3 USD/kg" 2>/dev/null); rc=$?
eq "blind runs" "$rc" 0
has "blind hides the parent trajectory" "$out" "parent=none traj=none"
has "blind passes only the given file" "$out" "files: ./project/project-memory.md "
has "blind uses the role prompt" "$out" "1"
has "blind --out writes the answer" "$(cat project/reviews/claim.md 2>/dev/null)" "parent=none"
out=$(PATH="$FAKE:$PATH" blind --role coldeyes 2>/dev/null)
has "coldeyes gets its default files" "$out" "./project/deliverable.md ./project/journal.md ./project/project-memory.md ./project/questions.md ./project/spec.md"
out=$(PATH="$FAKE:$PATH" LLM_USAGE_LEDGER="$WORK/wl.jsonl" PROJECT_LEDGER_MARK=1 PROJECT_WAKE_TOKENS=1000 \
    bash -c 'printf "{\"in_tok\":99999}\n{\"in_tok\":600,\"out_tok\":500}\n" > "$LLM_USAGE_LEDGER"; blind --role explorer "x"' 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "blind refuses once the wake spent its ceiling" || bad "blind refuses once the wake spent its ceiling" "$out"
has "refusal says what to do" "$out" "this wake has spent its token budget (1100 of 1000"
out=$(PATH="$FAKE:$PATH" LLM_USAGE_LEDGER="$WORK/wl.jsonl" PROJECT_LEDGER_MARK=1 PROJECT_WAKE_TOKENS=5000 blind --role explorer "x" 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "blind runs while the wake is under its ceiling" || bad "blind runs while the wake is under its ceiling"
has "blind runs are gitignored" "$(git -C "$P" status --porcelain)" "reviews/claim.md"
hasnt "blind scratch is not committed" "$(git -C "$P" status --porcelain)" ".blind"
cd /

# ── monolith step wiring (static) ────────────────────────────────────────────
step=$(cat "$REPO/thinkers/monolith/step")
has "step sources project.sh" "$step" '_lib/project.sh'
has "step picks the project prompt" "$step" 'prompt-project.md'
has "step commits project/" "$step" '_project_commit'
has "step caps each wake's steps" "$step" 'project_iter_flags=(--max-iterations'
has "blind caps its steps" "$(cat "$REPO/bin/blind")" '--max-iterations "$iters"'
has "blind reaches the sandbox" "$(cat "$REPO/thinkers/_lib/common.sh")" 'chat recap blind'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
