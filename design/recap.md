# `recap` — trajectory summarization with step references

Status: COMPLETE — bin/recap plus the web Recap tab/API (server.py, recap.tsx) implement the full design.

**Status:** Implemented
**Date:** 2026-07-17

## Problem

A living identity's mind log grows into thousands of steps (nick-web-2's
first day: 2,176 steps, of which 625 are `idle` ticks). The web dash lets
you *dig* — timeline, mind log, sub-trajectory views — but there was no way
to *grok*: "what has this agent been up to, at what altitude did its focus
move, and where in the log did the interesting things happen?"

`shellm-explore --report` is adjacent but wrong-shaped: it analyzes **run
trees** (a task run and its forks), produces free prose with no step
references, and slurps whole contexts into one prompt — none of which
scales to a long-lived mind log.

## Design

`bin/recap` is a small composable CLI in the standard shellm mold: reads
env (`TRAJ_DIR`/`TRAJ_ID`, so plain `recap` inside an identity shell
summarizes that identity's mind log), state is plain files, LLM access
goes through `llm`.

### Map-reduce over the log

1. **Filter.** Keep steps that carry narrative signal — `thought`,
   `action`, `observation`, `message`, `feedback`, `final`, `shellm-run`,
   `merge` — and drop `idle`, seed thoughts, and sub-run internals
   (`reasoning`, `shell-output`, `prompt`). Each kept step renders as one
   line: `[8-char-id] type(source): content…` (content truncated to 500
   chars). Rendering is NUL-safe and rides raw jsonl line numbers for the
   bookkeeping below.

2. **Map: windows → episodes.** The filtered stream is chunked into
   windows, and each window goes to the LLM (one call) which returns
   strict JSON: a title, a 2–4 sentence summary, 1–4 kebab-case themes,
   and 3–6 *notable steps* — each a step id that literally appears in the
   window plus a short note. One window = one **episode**, appended to
   `recap/episodes.jsonl` with provenance (source line range, first/last
   step ids and timestamps, model, created).

   **Window boundaries are gap-aware.** A window closes at the first of:

   - a **time gap** of ≥ `--gap-minutes` (default 30) before the next
     step, provided the window already has ≥10 steps — mind logs have
     natural sessions (agent stopped, overnight idle, between chats), and
     cutting there makes episodes read like chapters;
   - `--window` steps (default 100), the hard size cap;
   - ~60KB of rendered text (`RECAP_MAX_WINDOW_BYTES`), so a run of fat
     observations can't blow the token budget.

   Gap math converts each `ts` to UTC epoch-minutes by hand (jq
   arithmetic, days-from-civil) because mind logs mix timezones —
   inner_monologue stamps `+0800` while the actor stamps `+0000`, and
   naive string comparison would see 8-hour phantom gaps. Unparseable
   timestamps simply never trigger a gap cut. Cut points are
   deterministic functions of the data already seen, so incrementality
   is unaffected.

3. **Reduce: episodes → themes.** All episode summaries (not the raw log)
   go to the LLM once, returning an **arc** (1–2 narrative paragraphs) and
   3–8 **themes**, each with a description, the episodes it spans, and key
   step references borrowed from the episodes' notable steps. Written to
   `recap/themes.json`.

Step ids are the connective tissue: every claim in the output is anchored
to `[8-char id]` references that resolve in the web dash's mind log.

### Cache & incrementality

Everything lives under `<traj-dir>/recap/` next to `trajectory.jsonl`:

```
recap/
  episodes.jsonl   # one episode per line, append-only in the common case
  themes.json      # the reduction; rewritten whenever episodes change
  .lock            # mkdir-based mutex while a recap runs
```

The mind log grows continuously, so refresh must be cheap:

- Each episode records the raw jsonl line range it covers. A refresh
  resumes after the last episode's `raw_end_line` — **only new steps get
  summarized**.
- A trailing chunk smaller than the window becomes a **partial** episode
  if it has ≥15 steps (`--min-tail`), else it's deferred to the next
  refresh. On refresh, a partial tail episode is dropped and re-summarized
  from its recorded start line, so it fills out into a full window over
  time. Completed (non-partial) episodes are never re-summarized.
- The reduce step reruns only when episodes changed (or `themes.json` is
  missing). A refresh with no new steps makes zero LLM calls.
- `--rebuild` drops the cache and starts over (e.g. after a prompt or
  model change). `--cached` prints without any LLM access.

### Models

Map and reduce take separate models; **both default to the smart model**
(`RECAP_MODEL` → `SHELLM_MODEL`). The stages have different demands:

- *Map* is compression — high call volume (scales with log length
  forever), modest skill required. `RECAP_MAP_MODEL` / `--map-model`
  exists so it can be dropped to a cheap model if cost ever matters.
  Note that episodes are cached forever, so a cheap map model's output
  quality is locked in until a `--rebuild`.
- *Reduce* is synthesis — one call over a couple KB of episode summaries,
  and it produces the arc/themes you actually read first. Keep it smart
  (`RECAP_REDUCE_MODEL` / `--reduce-model` to override).

Cost intuition: a 2,000-step day ≈ 1,000 filtered steps ≈ 10 window calls
plus 1 reduce call — roughly 50k input tokens total, i.e. cents on a
Sonnet-class model.

### Concurrency & safety

- `mkdir recap/.lock` is the mutex (atomic on every filesystem); a lock
  older than 30 minutes is treated as a crash leftover and reclaimed.
- The trajectory itself is **never written** — recap appends no steps, so
  running dispatchers/thinkers see no new events and are unaffected.
  (Contrast `run-summary`, which is a step *in* the trajectory.)
- No other tool can mistake `recap/` for a trajectory: child-trajectory
  discovery follows `fork` steps and requires a `trajectory.jsonl`
  inside, and identity discovery prunes `trajectories/` entirely.
- Model output must be exactly one JSON object before a summary is written.
  Markdown fences are stripped, and an unusable response is retried once.
  Empty responses, arrays, scalars, malformed JSON, and multiple documents
  are rejected. Model refusals retain their separate handling.

## Web dash integration

Standard shape: the CLI owns the logic, the web layer moves bytes.

- `GET /api/identities/{id}/recap` — serves the cached themes + episodes,
  plus `refreshing` (lock present) and `new_steps` (raw lines beyond what
  the recap covers, i.e. staleness). Works in read-only mode.
- `POST /api/identities/{id}/recap/refresh` — fire-and-forget `recap -q`
  with the identity's env (same pattern as thinker steps: it can run for
  minutes, so don't block the request; the client polls the GET).
  `{"rebuild": true}` for a full redo. 409 if a recap is already running;
  403 in read-only mode.
- **Recap tab** (between Timeline and Mind log): arc, theme cards,
  episode list. Every step reference is a chip linking to
  `/i/<id>/mindlog?step=<8-char-id>`; the mind log resolves the prefix
  against its steps, scrolls there and flashes a highlight. Action steps
  that triggered a shellm run render as the run group's header, so the
  deep link falls back to the triggered run's element.
- Refresh button = incremental; shift-click = rebuild. The page polls
  while `refreshing` and shows "N steps since" staleness.

## Format notes

- `episodes.jsonl` entry: `idx`, `raw_start_line`/`raw_end_line`,
  `first_step`/`last_step`, `first_ts`/`last_ts`, `n_steps`, `partial`,
  `model`, `created`, then the LLM fields `title`, `summary`, `themes[]`,
  `notable_steps[{step, note}]`.
- `themes.json`: `generated_at`, `model`, `episodes` (count),
  `raw_end_line`, `total_lines`, `arc`, `themes[{name, description,
  episodes[], key_steps[{step, note}]}]`.
- Since the cache lives under `trajectories/`, `identity export` carries
  recaps with the identity; import needs no special handling.

## Testing

- `tests/test_recap_response_validation.sh` checks response shape, returned
  content, retries, and refusal status. CLI cases cover episode and theme
  failures and recovery, plus partial context when a rollup cannot be built.
- `tests/test_recap.sh` (25 checks) stubs `llm` with canned JSON and
  exercises the real filtering/windowing/caching machinery: idle+seed
  exclusion, window math, partial-tail lifecycle, incremental no-op, JSON
  output, rebuild, locking.
- `web/tests/test_recap_api.py` covers cache serving, staleness,
  refreshing flag, fire-and-forget CLI invocation, lock conflict (409),
  and read-only gating.

## Future directions

- **Recap-on-cadence thinker**: a thinker that runs `recap -q` after every
  N steps so the tab is always fresh (recap adds no trajectory steps, so
  this can't feed back into dispatch).
- **Self-context**: feed `recap --cached --json` back to the agent — a
  cheap autobiographical memory layer for "what have I been doing this
  week?" (very Headlong: the recap is a compressed self-narrative).
- **Hierarchical reduce**: when episodes number in the hundreds, add a
  second map level (episode groups → chapters) before the theme reduce.
- **Semantic window boundaries**: gap-aware cutting covers the natural
  seams; LLM-chosen or embedding-based cut points would add calls and
  complexity for marginal gain, since the reduce already smooths over
  imperfect boundaries. Revisit only if episode titles feel consistently
  mid-thought.
- **Sub-trajectory recaps**: the tool already takes any trajectory id;
  the web tab currently only surfaces the root mind log.
