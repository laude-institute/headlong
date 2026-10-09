# Monolith run health — stop wasting wakeups on bloat and silent errors

Status: draft
Relates to: [monolith_thinker.md](monolith_thinker.md), [monolith_backoff.md](monolith_backoff.md), [tiered_memory.md](tiered_memory.md)

## Motivation

The monolith now wakes reliably (scheduled-wake fix) and its runs execute
(bash-3.2 `${n^^}` fix). But watching a live identity (cleo, ~19k steps on
grok-4.6) shows most spontaneous wakeups still produce **nothing durable** — the
run reasons, shells around, and ends as a bare `idle`. Two independent causes,
both measured, not guessed:

1. **Context bloat / thrash.** The wakeup prompt is ~66 KB (~16.5k tokens). The
   run spends itself just reading and re-chunking its own prompt and never picks
   a function to carry out.
2. **Silent run death.** Runs die with `rc=141` (SIGPIPE) far more often than
   they succeed, and the step counts an errored run as an ordinary `idle` — so
   the failure is invisible and it drives the idle backoff as if nothing was
   wrong.

The net effect is a mind that looks alive (it wakes, it reasons) but rarely
*advances* — and neither failure surfaces anywhere an operator would see it.

## Issue A — context bloat and thrash

### Evidence

Components of cleo's `route_prompt`, measured directly:

| component | chars | ~tokens |
|-----------|-------|---------|
| `system_prompt` | 15,693 | 3,900 |
| `recent_stream` (tail 30) | 7,329 | 1,830 |
| **`life_context` (tiered rollups)** | **39,357** | **9,840** |
| `prompt.md` | 3,787 | 950 |
| **total** | **~66 KB** | **~16.5k** |

Two compounding problems behind that `life_context` figure:

1. **The budget is a fraction of the *model* window.** `_life_context` calls
   `recap --context --budget "${MONOLITH_CONTEXT_BUDGET:-auto}"`, and `auto` =
   ~0.6 × the model's context window. grok-4.6's window is **500k tokens**, so
   "auto" authorizes an enormous life section, and the rollup staircase fills a
   big chunk of it (~10k tokens observed, and it grows with trajectory length).
   A budget meant as "a comfortable slice of context" becomes "10k+ tokens of
   summary every wakeup" on a huge-context model.

2. **The trajectory itself is 312 MB.** `prompt` steps embed the full context,
   and `shellm-run` steps embed the entire `route_prompt` as a command-line
   argument — each ~64 KB. Over 19k steps that is a 312 MB `trajectory.jsonl`.
   Consequences: every `traj cat` reads 312 MB; and inside the run the model
   *re-fetches its own wakeup prompt* (`traj show <prompt-step> --full` → 64 KB
   → "extract first 8000…"), doubling the bloat it is already drowning in.
   (`_recent_stream`'s allowlist already excludes `prompt`/`shellm-run`, so these
   don't inflate the tail — but they bloat storage, slow every traj read, and
   are what the model keeps re-reading.)

### Proposed fixes

**A1 — Bound the life budget by an absolute ceiling, not a window fraction.**
Change the monolith's default so `MONOLITH_CONTEXT_BUDGET` resolves to an
absolute token cap (proposal: ~4,000 tokens) rather than `auto` on
large-context models. Keep `auto` available, but define it as
`min(fraction × window, ABSOLUTE_CEILING)` so a 500k / 1M / 2M window doesn't
translate into a 10k+ token life section every single wakeup. The recap
staircase is designed to fit any budget; this just picks a sane one. Net: the
life section drops from ~10k to a few thousand tokens with no code change to
recap — only the default the monolith passes.

**A2 — Blob large fields generically (currently only `stdout`/`stderr`).**
`traj`'s spill is *not* generic — `cmd_append` has two hardcoded blocks, one for
`stdout` and one for `stderr` (each: `if bytes > SHELLM_STDOUT_INLINE_LIMIT` →
write blob + record `*_ref`/`*_bytes`/`*_truncated`), and `next_blob_id` only
matches `*.stdout`/`*.stderr`. `content` (on `prompt` steps) and `command` (on
`shellm-run` steps) were simply never wired in, so the full ~64 KB `route_prompt`
lands inline on every such step — that is what makes the trajectory 312 MB.

Replace the two copy-pasted blocks with **one loop that spills any oversized
*string* field**, so no fat field is ever forgotten again. Guards that make
"generic" safe rather than reckless:

- **String-only.** Only spill string-valued fields; never blob a structured
  field (`usage` object, arrays, numbers) as a raw string.
- **The threshold already protects structure.** `type`, `step_id`, `ts`,
  `run_id`, `source`, the `*_ref`s — all are far under the inline limit, so a
  pure size rule leaves them inline automatically; no denylist strictly needed
  (a tiny keep-inline set for fields used in hot matching is optional
  belt-and-suspenders).
- **Generalize the read side too — this is the real work.** Today only
  stdout/stderr *readers* resolve `*_ref`. If any field can become a ref, every
  consumer that reads a potentially-large field must rehydrate it or silently
  see the truncated head. Ship a single `*_ref`-resolving helper that `traj
  show`, `recap`, `traj search`, the web `trajectory.py` reader, and the
  responder's `reply_to`/`content` scan all call. The write side is trivial; the
  blast radius is the readers, so the resolver is the deliverable, not the spill.

Net: trajectory shrinks ~1–2 orders of magnitude, every reader parses far fewer
bytes per line, and the giant step the model keeps re-fetching is gone. Better
still, avoid the `command` blob entirely by not putting the prompt on the
`shellm-run` command line at all — pass it via stdin/file so `command` stays
short and there is nothing to spill.

**A3 — Reads must not scan the whole file (finish a half-done migration).**
Big files only hurt on *reads*, and the mind does several per wakeup. The tail
approach the user proposed is right — and `traj tail` already implements it
efficiently (`tail -n N <file>`, seek-from-end, O(N) not O(file)); `common.sh`
even added `_root_traj_raw_tail` (`tail -n 5000 <file>`) after a 532 MB file
caused a 78 s context build. The problem is the migration is unfinished, in
three concrete steps:

1. **Convert the remaining bash scanners to the tail path.** `_last_work_id`
   (monolith/step) still does `traj cat --raw | jq | tail -1` — a **full-file
   scan, twice per wakeup**. Point it (and any sibling scanners) at the same
   tail fast-path `_recent_stream` already uses.
2. **Add a filtered backward tail primitive.** "Last N *steps of type T*" is not
   "last N lines" — machinery steps dilute the tail, which is why
   `_recent_stream` over-reads a fixed 5000 lines (and silently under-reads if
   machinery ever exceeds that window). Add `traj tail --types … -n N` that reads
   **backward until it has N matches** (bounded, exact), and route
   `_recent_stream` and the TUI's phase-1 load (`traj cat --filter | tail -20`,
   currently O(file)) through it.
3. **Unify on a *contract*, not a single binary.** You cannot literally share
   one reader across bash (`traj`), Python (web), and Rust (TUI). What must be
   shared is the on-disk *format* — JSONL + blob refs + tail/window semantics,
   i.e. [trajectory_spec.md](trajectory_spec.md) — with an efficient reader per
   language. Two already exist and are good: `traj tail`, and the web's
   `trajectory.py` (byte-offset `seek`, append-aware incremental cache,
   "O(budget+chunk), never O(file)", O(new-steps) polls). **So do *not* make the
   web shell out to `traj`** — that would add a subprocess per request and throw
   away its incremental cache; it is already the reference efficient reader. The
   TUI already goes through `traj` (Rust shelling out) and just needs the better
   filtered-tail command from step 2. The genuine gap is the bash `traj` tool +
   the thinker scanners (steps 1–2); once those use the efficient tail, "route
   bash consumers through traj" is satisfied without touching the good Python/
   Rust citizens.

Note A2 and A3 are complementary, not redundant: A3 bounds the *number of lines*
a read touches; A2 bounds the *bytes per line*. `tail -n 5000` over 16 KB/line
steps still reads ~80 MB; blobbed, ~1 MB. Every reader wants both.

**A4 — Tell the model it already has its context (prompt hygiene).** The router
prompt should state plainly that the wakeup context *is* the message it just
received — it does not need to `traj show` or re-read anything to "get the full
prompt." Cheap, and directly targets the observed thrash loop.

## Issue B — runs die silently and are miscounted as idle

### Evidence

Run outcomes in cleo's monolith log (the `rc=` on "run produced no work"):

| rc | count | meaning |
|----|-------|---------|
| 0 | 40 | clean |
| 1 | 161 | the `${n^^}` bash-3.2 abort (now fixed) |
| **141** | **435** | **SIGPIPE** |

`141 = 128 + SIGPIPE(13)`. The run does real intermediate work (reasoning steps,
shell commands each `Exit 0`) and then the **shellm process itself** exits 141
before landing a durable thought/action step.

### Root cause 1 — `producer | head` under `pipefail`

`bin/shellm` runs under `set -euo pipefail` globally. Two pipelines pipe a
still-producing command into `head`, which closes the pipe early → the producer
gets `SIGPIPE` → `pipefail` propagates 141:

- The streaming output reader (executed each poll while a command runs):
  ```sh
  tail -n +"$skip_n" "$output_file" | head -n "$new_count" | while IFS= read …
  ```
  `new_count` is computed from a `wc -l` snapshot, but the output file is being
  **written concurrently** by the running command. When more lines arrive
  between the snapshot and the read, `head` stops at `new_count` while `tail`
  keeps reading the freshly-appended lines → SIGPIPE. Substantial streaming
  output makes this likely — which is exactly the monolith's profile.
- `_find_latest_traj`: `… | sort -rn | head -1 | cut …` (same class; fires on
  traj resolution).

### Root cause 2 — the step conflates "errored" with "idle"

`thinkers/monolith/step` classifies a wakeup purely by *did a work-type step get
appended?* A run that reasoned, executed commands, then **died at rc=141** looks
identical to a run that calmly decided there was nothing to do: both append a
fallback `idle`, both advance the backoff toward the cap, and both render as a
plain `idle` on the timeline. The error is completely invisible, and — because
it looks like healthy idling — it silently slows the mind down.

### Proposed fixes

**B1 — Make shellm's internal pipelines SIGPIPE-safe.** For the pipelines that
feed `head`, either scope `set +o pipefail` around them, or restructure so
`head` cannot close early (read to EOF; or bound with `sed`/awk instead of a
concurrently-racing `tail | head`). A SIGPIPE in a best-effort *display/read*
step must never be the exit code of the whole run. Add a regression test that
streams a large, still-growing output through the reader and asserts rc 0.

**B2 — Distinguish errored runs from idle runs in the step.** Split the current
single "no work → idle" path:

- `rc == 0` and no work step → **genuine idle**: back off as today.
- `rc != 0` → **errored run**: append a `{type:"error", reason:"run-failed",
  rc:N}` step (visible on the timeline and to the operator), and do **not** treat
  it as a clean idle for backoff. Instead apply a small, capped error backoff
  (so a persistently failing run cannot tight-loop and burn tokens, but also
  isn't mistaken for "resting"). This reuses the stall-guard philosophy already
  in `bin/shellm` — surface the failure, bound the spend.

**B3 — Count intermediate work.** A run that appended `reasoning`/`shell-output`
but no durable thought/action still *did* something. At minimum, record it so
the timeline and the backoff can tell "reasoned but landed nothing" apart from
"chose to idle." (Optional: nudge the router prompt to always conclude a
non-idle run with a durable step — a thought summarizing what it learned — so
real work isn't discarded when the run ends.)

## Issue C — the model keeps writing after its code block until the transfer times out

### Evidence

Audel on grok-4.6, 2026-09-02: 22 of 187 monolith runs died as `error`
steps with `rc=1`. Every one had the same shape in `monolith.log`: a few
normal steps, then ten minutes of silence, then

    llm: error: curl error: curl: (28) Operation timed out after 600000
    milliseconds with 12237224 bytes received

All 116 such timeouts in the log had received more than 5 MB, so they were
runaway generations, not dead connections. The streamed text shows what
the model was writing: a small code block, then the trajectory's own step
rendering imitated back (`[in_tok]`, `[llm_s]`, `[out_tok]`, `[run_id]`,
`[think_tok]` with invented numbers), then a fresh thought and a second
block (`echo ping649`, `echo ping650`, ...), 1,337 fences in one run. At
grok's 67 tokens per second the 64,000 token cap cannot be reached inside
`LLM_MAX_TIME`, so the run always lost the step and the wake.

Over the 2,471 most recent responses, 2,300 had nothing after the first
closed block. 165 continued with the fake metadata pattern, doubling from 4
to 9 percent across the sample. None had genuine prose after the block.
`bin/shellm` executes only the first block and drops the rest, so nothing
kept was ever in the discarded tail. Same day, 18 and 21 failures on
2026-08-24 and 2026-08-29 show it was not new.

### Root cause

`bin/context` rendered every non-meta field of a past step as `[field]`
then value, including the bookkeeping `bin/llm` and `bin/shellm` stamp
(token counts, latency, run id). The model saw dozens of those blocks per
prompt right after its own commands and continued the pattern.

### Fixes (built 2026-09-03)

1. `bin/context` hides `run_id`, `llm_s`, `in_tok`, `out_tok`,
   `think_tok`, and `estimated` (`is_meta`). The imitated template is gone
   from the prompt. `tests/test_context.sh` has the invariant.
2. `bin/llm --stop-after-code-block` (`LLM_STOP_AFTER_CODE_BLOCK=1`) stops
   reading the stream the moment the first fenced block closes, using the
   same heredoc-aware fence rules as `extract_code`. curl then dies on its
   next write, which the retry loop treats as a clean finish, and the usage
   record is estimated from bytes with `estimated: true` since the
   provider's usage event never arrives. `bin/shellm` passes the flag by
   default (`SHELLM_STOP_AFTER_CODE_BLOCK=0` reads to the end).
   `tests/test_llm_stop_after_code_block.sh` covers the runaway, heredocs
   holding fences, a tagged fence hanging off prose, and no-block answers.

Together: a loop that starts after the block now ends the step normally,
with the command it was going to run, instead of a ten minute stall and a
dead run. A loop that starts before any block closes is not caught; a
repeated-line guard would be the next net if the timeouts persist.

## Issue D — a step that never exits leaves the mind silent

### Evidence

2026-09-14 18:34Z: a wake answered a Telegram question about identity
creation by creating one on the box, and inside the run it started two
`headlong-web` servers with `nohup ... &`. The run finished normally and
wrote its final step at 18:45:37Z. The monolith step then sat in `read()`
for six hours. The dispatcher was alive and ticking, every unit reported
active, and Audel's trajectory did not grow until an operator killed the
servers at 01:40Z the next day.

### Root cause

The step captured the run with `run_response=$( ... shellm ... )`, which is
a pipe. A pipe reaches end of file only when every holder of its write end
closes it, and a backgrounded process inherits every fd the run had open.
The servers held the pipe, so the command substitution never returned, the
step never reached its EXIT trap, and `arm_wake` never wrote the next
`wake_at`. Under `trigger_self:false` the EXIT trap is the only source of
the next wake, and no watchdog covers a monolith subscription (the
liveness watchdog applies to `trigger_self` thinkers only). Nothing
noticed: the death and failure alerts watch the unit, and the unit was
fine.

### Fixes (built 2026-09-15)

1. **Files, not pipes** (`thinkers/monolith/step`). shellm's stdout and
   stderr go to temp files; a `tail -F` streams stderr to the step log
   while the run works. The step now waits only for its direct child.
   After the run it lists any process still alive in its process group
   (Linux, where setsid gives each step its own) as a WARNING in the log.
   Leftovers are reported, not killed: a backgrounded sub-run can be
   deliberate.
2. **Stuck-step guard** (`bin/thinkers`, `THINKERS_STEP_GRACE`, default
   300s, 0 disables). The dispatcher remembers which thinker launched each
   `shellm-run` (its `launched_by`; shellm blanks it for nested runs) and,
   when the matching `final` arrives while that step is still alive,
   starts a grace clock. A step alive past the grace gets TERM (bash runs
   its EXIT trap on TERM, so the monolith still arms its next wake), KILL
   15s later, one `error` step with `reason: step-stuck`, and a STUCK line
   in the dispatcher log naming what else was alive in its group. A step
   with no final, or a final from a run it did not launch, is left alone
   by this guard. The quiet-step guard (`THINKERS_STEP_QUIET`, default
   5400s, 0 disables; added 2026-10-09) covers that case: every busy step
   has a quiet clock that starts at dispatch and restarts on each step of
   the run it launched, and a step whose clock passes the limit is ended
   the same way with `reason: step-quiet`. The default sits above
   `SHELLM_MAX_EXEC_TIME` (3600s), the longest a healthy run goes between
   steps. It exists because a run can wedge before its final for reasons
   nobody has listed yet (2026-10-07: shellm echoed 27M trace lines of a
   dead command for 26 hours).
3. **Silence alert** (`deploy/thinkers-silence-alert.sh`,
   `headlong-thinkers-silence@<identity>.timer`, every 5 min). If the
   dispatcher pid is alive, no deliberate stop is marked, and the root
   trajectory has not been touched for `HEADLONG_SILENCE_SECS` (default
   1800s, six times the 300s backoff cap), post one "gone quiet" message
   to the alert channel and write `run/silent_since`; post "is back" and
   drop the marker when steps resume. A dead dispatcher is the death
   alert's job and posts nothing here. The timer is armed by
   `headlong-thinkersctl start|restart` and by `deploy/update.sh` for
   every identity with a thinkers unit.

Tests: `tests/test_monolith_run_capture.sh` (a stub run leaves a
background process holding every fd; the step must still return, keep
both streams, arm the wake and name the leftover),
`tests/test_thinkers_stuck_step.sh` (guard fires after the grace, EXIT trap
runs, error step appended; no final or a foreign final leaves the step
alone; grace 0 disables), `tests/test_thinkers_silence_alert.sh` (alert,
one per episode, recovery, dead dispatcher and deliberate stop are silent,
missing config degrades to the fallback log).

Not done here, still open: a scratch home for the mind's experiments so a
nested identity never lands in the production `.identities/` (the same
class of incident as 2026-09-08, 09-09 and 09-12).

## Rollout & testing

Order matters — B before A, so we can *see* the effect, and cheap/high-leverage
before big refactors:

1. **B1** (SIGPIPE-safe pipelines) + regression test — stops the dominant
   failure; run count should shift from mostly-141 to mostly-0.
2. **B2** (error vs idle split) — makes any remaining failures visible on the
   timeline instead of masquerading as idle.
3. **A1** (absolute budget default) — one-line default change, highest-leverage
   bloat fix; verify the life section drops to a few thousand tokens.
4. **A3 step 1** (convert `_last_work_id` to the tail path) — removes a full-file
   scan per wakeup with an existing pattern; near-free.
5. **A4 / B3** (prompt hygiene + count intermediate work) — cheap prompt/step
   changes; verify the run stops re-fetching its own prompt and lands durable
   steps more often.
6. **A3 step 2** (filtered backward `traj tail --types`) — the one new primitive;
   re-point `_recent_stream` and the TUI phase-1 load at it.
7. **A2** (generic blob-spill + shared `*_ref` resolver) — the storage/perf fix;
   verify a fresh identity's `trajectory.jsonl` grows ~1–2 orders of magnitude
   slower and every reader stays fast at scale. Biggest blast radius (the read
   path), so last.

A3 step 3 (contract, not binary) is a framing that guides 1–2 and A2's resolver,
not a separate task — and explicitly *excludes* rewriting the already-efficient
web `trajectory.py` reader.

Validate on cleo (the reproduction case): after B+A, spontaneous wakeups should
mostly produce a durable `thought`/`action`/`observation`, `rc=141` should
disappear, and the backoff should reflect genuine idleness rather than masked
errors.

## Non-goals / alternatives

- **Not** reducing what the mind *can* remember. A1 bounds the per-wakeup
  *budget*, not the rollup pyramid — the full tiered history remains; the
  staircase just fits a smaller window (its entire purpose).
- **Not** switching models. grok's huge window is fine; the bug is treating
  "0.6 × 500k" as a reasonable per-wakeup budget.
- Considered: trapping `SIGPIPE` globally in shellm (`trap '' PIPE`). Rejected as
  too broad — it would also hide legitimate broken-pipe errors in executed code.
  Scope the fix to the specific display/read pipelines (B1).
- Considered: dropping `pipefail` in shellm. Rejected — pipefail catches real
  errors elsewhere; the fix is the two offending pipelines, not the safety net.
- Considered: making every consumer shell out to `traj` for one access layer.
  Rejected for the web server: `web/.../trajectory.py` is already an efficient
  append-aware reader (byte-offset seeks, O(new-steps) polls, O(budget) memory);
  a subprocess-per-request wrapper around bash `traj` would be slower and throw
  away its incremental cache. The unifying interface is the *format spec*, not a
  single binary — see A3 step 3.
- Considered: a byte-offset index / log segmentation for O(1) recent-step reads.
  Deferred — the tail-path + blobbing (A2/A3) keep reads flat well past current
  scale; a persistent index only earns its complexity at millions of steps.
