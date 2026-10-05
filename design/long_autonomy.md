# Project mode: weeks of unattended research

Status: implemented (opt-in), not yet exercised against a real model.
Code: `thinkers/_lib/project.sh`,
`thinkers/monolith/prompt-project.md`, the project hooks in
`thinkers/monolith/step`, `bin/blind`, `tools/headlong-project`, and the
templates in `identities/project/`. Test: `tests/test_project_mode.sh`.

## The problem

Headlong was built for a persistent companion. Many people talk to it, it
picks its own interests, and conversation keeps it pointed somewhere.
Take the people away and give it one research project for two or more
weeks, and four things go wrong:

1. **Drift.** The stock persona and menu reward curiosity: `think`,
   `values`, `share`, "explore Headlong itself". With no one steering, the
   mind wanders off the project or circles over it.
2. **No discipline over claims.** Nothing separates a sourced number from
   a plausible one. Nothing makes the mind attack its own results, and no
   reader with fresh eyes ever sees the work.
3. **Blocking on humans.** A real research question needs a human call
   (a discount rate, a system boundary). With nobody to answer, the mind
   either stalls forever or guesses silently.
4. **Unbounded cost, invisible state.** A mind thinks around the clock.
   Two weeks with no budget and no versioned record is expensive, and
   afterwards nobody can tell what happened.

The CNS Bot prompt library (`CNS_Bot_Prompt_Library.md`) answers 1 and 2
with a fixed charter, a file-based project record and daily and weekly
rituals. It assumes weekly human check-ins and a scheduler around the
model. Headlong already has the scheduler (the dispatcher and the
monolith's backoff), a context that is rebuilt on every wake, and
trajectories that keep everything. Project mode combines the two: the
CNS discipline, carried out by Headlong's runtime rather than by prompts
on a timer.

## Design principle: the runtime decides, the model does

Anything that must happen whether or not the model remembers is done in
deterministic shell, in the monolith step, around the model's run:

| Concern | Who handles it |
|---|---|
| Charter and spec stay unedited | Runtime: restores them from `project-pristine/` every wake and logs an `error` step |
| A ritual is due | Runtime: a ritual is due when its output file is missing (`daily/DATE.md`, `reports/week-NN.md`) |
| A question's default has matured | Runtime: parses `questions.md` and raises DEFAULT DUE |
| Budget | Runtime: sums the `usage/llm.jsonl` ledger over 24h, paces each wake by its own cost, and caps the steps in a wake |
| Deadline | Runtime: shows days left and the phase (build, harden, final) on every wake. Flags a missing or stale deliverable. Runs a final ritual at the end, then rests. |
| Question provenance | Runtime: commits between-wake edits as author "human", and checks who wrote each Answer line from git |
| Blocked or done | Model writes `STATE`. The runtime turns it into a rest pace (one wake an hour) |
| Stall | Runtime: STATE is active but `journal.md` unchanged for 12h raises STALL |
| Versioning | Runtime: `git commit` of `project/` after every wake, with FINAL as the message |
| Doing the work, curating, reviewing | Model, one function per wake, from `prompt-project.md` |

Rituals keyed to output files fail safe. A ritual killed by a crash or a
budget stop is simply still due on the next wake. A ritual is never
skipped because a timer fired while the mind was busy.

## Mapping the CNS library onto Headlong

| CNS library | Project mode |
|---|---|
| §1 Who Am I (immutable) | `project/charter.md`. Shown on every wake, ahead of the persona, and restored if edited. Rewritten for zero human contact (see below). |
| Spec inside project-memory | Split out to `project/spec.md` (read-only), so "do not silently reinterpret" is enforced, not only requested |
| §2 Addenda | `project/addenda.md`, tended in the weekly ritual |
| §3 Project memory | `project/project-memory.md`. Data rows carry an "Adversary review" column, plus a section for interpretation calls made without a human |
| §4 Journal | `project/journal.md`. Every work wake must append an entry. The last 5 entries are in every wake prompt. |
| §5 Daily eval | `project/daily/DATE.md`. Writing it is what clears the daily ritual. |
| §6 Questions | `project/questions.md`, with Q ids and `Default:`, `Default-by:`, `Answer:` and `Resolution:` lines the runtime reads. Open questions lead every human status view, and `questions-summary.md` lists how each closed. |
| §7 Progress report | `project/reports/week-NN.md`, with a new section listing every call made without a human |
| §8, §9 Skills | `project/skills/project/` and `project/skills/generic/`. Headlong's `mem` store still holds cross-project lessons. |
| §10 Restart prompt | Unnecessary: every wake is a restart. Charter, spec, memory, journal tail and questions summary go into each prompt. |
| §11 Every-2-hours refresh | Same reason. The context is rebuilt from the files on every wake, so it cannot go stale. |
| §12 Daily bundle | `rituals/daily.md`, injected when due (after `PROJECT_DAILY_AT`, 21:00 local by default) |
| §13 Weekly bundle | `rituals/weekly.md`, due from the first wake of the next project week |
| §14 Cold-eyes review | `blind --role coldeyes`: a fresh agent that sees only spec, memory, journal and questions |
| §15 Free time | `rituals/freetime.md`: a 12h window on project day 6 of each week (`PROJECT_FREETIME=0` turns it off) |
| Adversarial subagents | `blind --role adversary`, required before a number enters project-memory |
| Independent exploration | `blind --role explorer`, never told the favored approach |
| Versioning note | Automatic: `project/` is a git repo, committed every wake |
| "Display on the second monitor" | `STATE`, the weekly report and `headlong-project status`. The dashboard shows the trajectory as before. |

## Departures from the vision document, and why

- **No reliance on human check-ins.** The library assumes someone
  answers questions.md every week. Here a human may look in every few
  days, with no guarantee, so every question carries a default and a
  date. When the date passes, the mind
  applies the default and records it, with its risk, where a human will
  find it. `Default-by: never` marks a question too important to guess.
  The thread then stays blocked, and the report says so. This keeps the
  library's "stop rather than guess" rule while still ending every block.
  The alternatives were stalling for two weeks or guessing silently.
- **Subagents are blind by construction.** In Headlong, a nested `shellm`
  forks its parent's trajectory, so a "subagent" sees the whole mind log,
  including the parent's favored approach and its self-assessment. That
  quietly defeats §1's subagent rules and §14's isolation. `bin/blind`
  starts a root run with no parent trajectory, its own trajectory dir,
  and a scratch directory holding copies of only the files it was
  given. Its runs stay in `project/.blind/` (gitignored) for audit.
- **No separate refresh prompts.** The library's restart and
  every-2-hours prompts exist because a long-lived chat context goes
  stale. Headlong builds a fresh context on every wake, so the charter is
  never more than one wake old.
- **The menu changes.** `prompt-project.md` replaces think, values, share,
  recall and goals with ritual, work, verify, explore, decide, question,
  default, plan and rest. The responder still answers anyone who
  messages, but the monolith sends no unprompted messages. The weekly
  report is how the agent talks to humans.
- **Persona replaced.** `headlong-project init` swaps the curious-companion
  persona for a short research persona (the old one is kept as
  `core_identity_prompt.md.pre-project`). The stock persona's "explore
  your own workspace and Headlong itself" competes with the charter.
  `--keep-persona` opts out.

## The deadline and the deliverable

Honesty alone does not make a run converge. With hard stops and honest
rest, an agent can spend two weeks producing careful process (journals,
evaluations, reviews, a growing assumptions table) and no answer, or
declare itself blocked on day 4. Two things make the run converge on a
result:

- **An end date** (`project-pristine/end_at`, set by `init --days N`
  (default 14) or `--end DATE`, moved by `headlong-project deadline`).
  Every wake shows "day X of N", the time left and the phase:
  - **build**: the first half,
  - **harden**: the second half, which stresses checking over new scope,
  - **final**: the last 15% or 2 days, whichever is longer; no new scope
    and no free time.
- **One living deliverable** (`project/deliverable.md`): the current
  answer to the spec, written for the humans who asked, and usable if the
  run stopped at any moment. The template carries a marker line. After
  `PROJECT_DELIVERABLE_BY_DAYS` (1) with the marker still there, the wake
  says DELIVERABLE MISSING. A draft unchanged for
  `PROJECT_DELIVERABLE_STALE_HOURS` (48) is DELIVERABLE STALE.
  Cold-eyes reviews judge the deliverable against the spec first.

When the end passes, the final ritual is the only one due. It runs a
final cold-eyes review, finalizes the deliverable, writes
`reports/final.md` and sets STATE to done. After that the mind rests (one
wake an hour, nothing due). A human who extends a finished run reopens
it: the old final report is kept under a dated name, STATE goes back to
active, and the final ritual runs again at the new end.

## Questions and humans

Humans may look in every few days, with no guarantee. Questions are
built for both cases.

- **Visible while open.** Every open question leads `ada status` and
  `headlong-project status`, flagged with `!!!`. Each shows its Q id,
  whether it is blocking, its default and when the default applies, and
  the command to answer it.
- **Easy to find once closed.** `project/questions-summary.md` is
  regenerated every wake. It lists open questions first, then a table of
  closed ones and how each closed: human answer, default (with the
  default used) or moot. `headlong-project questions <name> --closed`
  prints the same.
- **Provable human answers.** A human answers with `headlong-project
  answer <name> Q3 "..."` or by editing questions.md. Either way the
  change is committed as author "human": the command commits it, and the
  monolith commits all edits made between wakes as "human" before the
  next wake starts. The runtime decides "a human answered" from `git
  blame` on the Answer line, not from its text. A question the agent
  marks answered without a human-written answer is flagged UNVERIFIED to
  humans, and QUESTION RECORD WRONG to the agent.
- **A human answer comes first.** The next wake gets a HUMAN ANSWER
  signal that outranks rituals. It also lifts a blocked agent's rest
  floor, so the answer is applied within one pacing interval.

One residual gap: a wake that crashes after editing project files but
before its commit has those edits attributed to "human" at the next
wake. The commit message says "a human, or a wake that crashed".

## Pacing and cost

Project mode keeps the monolith's backoff. Visible work re-arms at once,
thought-only wakes rest up to 60s, and empty wakes rest up to 300s. On
top of that:

- **Budget.** `PROJECT_DAILY_TOKENS`, which `init` sets to 2,000,000 (or
  `--daily-tokens N`), caps tokens processed over a rolling 24h. "Tokens
  processed" is input plus output, plus cached input on Anthropic-format
  providers, whose input count leaves cache reads out. So the same cap
  means the same work on any provider.
- **Pacing.** A wake that cost T tokens waits at least T/cap of a day, so
  a busy mind spreads the budget over the day. At a 2M cap, a 40K-token
  wake waits about 29 minutes. `PROJECT_PACE=0` turns this off.
- **Per-wake cap.** A wake is limited to `PROJECT_MAX_ITERATIONS` (25)
  steps, and a `blind` subagent to `BLIND_MAX_ITERATIONS` (30). Within its
  last `SHELLM_ITERATION_WARN` (3) steps, shellm appends a notice to the
  model's input, so it records its work and sets FINAL instead of being
  cut off. The cap bounds a wake's cost only roughly, since each step
  resends a growing context.
- **Per-wake ceiling.** A step cap bounds one model run, not a wake: a
  wake can start several `blind` subagents, each with its own steps. Each
  wake therefore gets a token ceiling covering its subagents
  (`PROJECT_WAKE_TOKENS`, by default half the daily cap, and never more
  than what is left of the run cap). The monolith hands the sandbox the
  ledger position it started at, `blind` refuses to start once the wake
  has spent its share, and the wake is told the ceiling and what a
  subagent typically costs. (On the first live run, one wake started two
  explorers and spent 1.3M tokens. Partly that was a stale copy of `blind`
  in a reused sandbox without its step cap. `shellm` now refreshes `--bin`
  tools whose checksum changed.)
- **Over budget, hard.** Over the daily cap or the whole-run cap
  (`PROJECT_TOTAL_TOKENS`), a wake makes no model call at all. It logs one
  step per pause and re-checks every `PROJECT_BUDGET_REST` (1800s). So a cap
  can be overshot only by the wake that crossed it, and the per-wake
  ceiling bounds that wake. Set the run cap below the true limit by one
  worst-case wake. A BUDGET warning appears at 80% of the daily cap, and a
  RUN BUDGET warning at 70% of the run cap.
- **Settings are pinned at start.** The dispatcher exports the identity's
  `.env` when it starts, so a changed setting takes effect only after
  `<name> stop; <name> start`.
- **Blocked or done, nothing due.** `PROJECT_REST` (3600s) is the floor,
  applied even after visible work. Every floor is the largest of those
  that apply.
- **Accelerated runs.** `PROJECT_TIME_SCALE=N` (`init --time-scale N`)
  runs the project clock N times faster: days, weeks, rituals, the
  deadline, staleness checks, pacing, rest floors and the budget day all
  follow it. The wake is told the project time and to date its files by it.
  `--days 9 --time-scale 48` is a nine-day project in four and a half hours.
- **Prompt caching.** On Anthropic-format providers (Anthropic, and both
  Bedrock modes), `llm` puts an explicit cache breakpoint on the system
  prompt and on the last message. So each step of a run reads the previous
  step's prefix from the cache. Verified live on Bedrock: a repeated 17K
  token prefix came back as 17,014 cache-read tokens and 4 new input tokens.
  Cache reads are billed at a fraction of the input rate. Cache writes are
  folded into `in_tok`, so budgets count them. Token budgets still count
  cache reads as tokens processed, so caching lowers dollars, not budget
  use. `LLM_PROMPT_CACHE=0` turns it off.
- **Smaller prompts.** The recent stream is 12 steps instead of 20,
  because the journal tail already carries the thread.

A messaged human triggers a reactive wake, and reactive wakes do not wait
for pacing. With humans rarely present this is small, but it is not
counted against the pace.

## Sizing the budget

From the first live run (Opus 5.5 on Bedrock, 2026-10-05; the full account
is below):

- One model step costs about 20K to 40K tokens processed, and grows over a
  wake as the run's context grows.
- A plain wake costs 15K to 80K. A wake with a blind subagent costs 150K
  to 400K or more.
- 2M tokens bought about 60 model calls. That covered scoping, a literature
  screen, and the question and final rituals, but not an LCA model.

For a real two-week run, budget roughly 2M to 4M tokens per day (28M to
56M in all). Set `PROJECT_TOTAL_TOKENS` to the true limit minus one
worst-case wake (about half a million tokens). With prompt caching on, most
of those tokens are cache reads, so the dollar cost is far lower than the
token count suggests.

## The first live run (2026-10-05)

- **Setup:** a sodium-ion LCA spec, nine project days at 48x, Opus 5.5 on
  Bedrock, a 2M token budget. It used 1.6M tokens in 72 calls.
- **What worked:**
  - Questions came with dated defaults. A human answer was committed as
    author "human" and applied. The defaults closed four questions.
  - The daily and final rituals ran. Moving the deadline worked.
  - The deliverable was honest: a literature screen with every number
    marked unaudited and every gap named.
  - A spot-checked figure matched its source exactly.
- **What it found, all fixed:**
  - `llm` capped current Claude models at 4096 output tokens.
  - A stall guard aborted non-streaming calls that thought for over a
    minute.
  - Model calls inside the sandbox never reached the usage ledger.
  - Reused sandboxes kept stale copies of `--bin` tools. A stale `blind`
    without its step cap cost about 700K tokens.
  - A wake's cost was unbounded once it started subagents.
  - Budget caps were soft.
  - Resting cost a model call every project hour.
  - Headlong sent no prompt-caching markers at all.
  - Bedrock was not supported, and `us-west-1` has no `bedrock-mantle`
    endpoint (hence `bedrock-invoke`).
- **What it taught:** the agent spent its budget on scoping and literature
  discovery before it had any number of its own. The charter and menu now
  require a crude end-to-end model on day 1 (function `model`,
  `project/model/`), and they treat subagents as the expensive tool.

## Configuration

Read from the environment or the identity's `.env`:

| Variable | Default | Meaning |
|---|---|---|
| `HEADLONG_PROJECT_MODE` | 1 | 0 turns project mode off without deleting files |
| `PROJECT_DAILY_TOKENS` | 2000000 (set by init) | 24h cap on tokens processed, from the usage ledger |
| `PROJECT_PACE` | 1 | Pace wakes by their cost (0 turns pacing off) |
| `PROJECT_TOTAL_TOKENS` | unset (`init --total-tokens`) | Cap on tokens for the whole run |
| `PROJECT_WAKE_TOKENS` | half the daily cap | Tokens one wake may spend, blind subagents included |
| `PROJECT_TIME_SCALE` | 1 (`init --time-scale`) | Run the project clock N times faster than real time, for tests |
| `PROJECT_MAX_ITERATIONS` | 25 | Steps per wake |
| `BLIND_MAX_ITERATIONS` | 30 | Steps per blind subagent |
| `SHELLM_ITERATION_WARN` | 3 | Steps before a cap at which shellm warns the model |
| `PROJECT_DELIVERABLE_BY_DAYS` | 1 | Days before a missing deliverable (crude model plus draft) is flagged |
| `PROJECT_DELIVERABLE_STALE_HOURS` | 48 | Hours before an unchanged deliverable is flagged |
| `PROJECT_BUDGET_REST` | 1800 | Minimum delay in seconds while over budget |
| `PROJECT_REST` | 3600 | Minimum delay in seconds while blocked or done |
| `PROJECT_DAILY_AT` | 21:00 | Local time (`HEADLONG_TZ`) that closes a project day |
| `PROJECT_FREETIME` | 1 | Weekly free time on or off |
| `PROJECT_FREETIME_DAY` | 5 | Day within the project week (0-based) when free time opens |
| `PROJECT_STALL_HOURS` | 12 | Hours without a journal change before STALL |
| `PROJECT_JOURNAL_ENTRIES` | 5 | Journal entries shown per wake |
| `PROJECT_MEMORY_MAX` / `PROJECT_SPEC_MAX` | 14000 / 16000 | Bytes of each shown per wake |
| `BLIND_MODEL` | `SHELLM_MODEL` | Model for blind subagents (a different model family makes a stronger reviewer) |

## Operator runbook

```bash
headlong-project init ada --spec brief.md --days 14   # sets a 2M tokens/day budget
ada stop; ada start
ada status                                     # open questions first, every time
headlong-project status ada                    # deadline, deliverable, budget, commits
headlong-project answer ada Q3 "Use 2024 USD"  # the agent applies it next wake
headlong-project questions ada --closed        # how every closed question closed
headlong-project deadline ada --days 21        # move the end (reopens a finished run)
git -C .identities/ada/workdir/project log     # the whole run, one commit per wake
```

To change the charter or spec mid-run (a human decision), edit
`.identities/ada/project-pristine/` and run
`headlong-project update-pristine ada`.

At the end of the run, read in this order:
1. `reports/final.md`
2. `deliverable.md`
3. `questions-summary.md` (every call made without you)
4. the weekly reports in `reports/`
5. `reviews/`

## Known limits

- The guard is tamper-evident, not tamper-proof. The mind can reach
  `project-pristine/` inside its sandbox. A deliberate edit there would
  survive, but git history in `project/` and the guard's error steps
  would still show the change. Mounting the pristine dir read-only in the
  sandbox would close this.
- `blind` isolates trajectory and working files, not the filesystem. A
  reviewer that goes looking outside its scratch directory can find the
  project. Its prompt tells it not to.
- Rituals are scheduled on the project clock (`started_at`), so a box
  that is down for days owes only the latest daily and the latest weekly
  ritual, not one per missed day.
- After the final report, the mind rests at one wake an hour until it is
  stopped or extended. Before the end, a mind that writes `done` keeps
  doing its rituals: a cold-eyes review after "done" is cheap and often
  finds something.
- Nothing pushes open questions to humans (Slack, email). They are
  visible in status and in the summary only when someone looks. A
  bridge post for each new blocking question is the natural next step.
- Status does not yet show the mind's health (recent error steps, last
  successful wake), so a provider outage looks like a quiet agent.
