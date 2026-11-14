# Related memories and the goals lifecycle

Decided with Nick on 2026-09-04, after the wake prompt cull
(wake_prompt_cull.md). Audel had 763 memory files, wrote about 20 a day, and
read one back only when it searched by hand. Goals were added and never
retired, and the prompt showed 3 of 13.

## Related memories

Each wakeup, the monolith adds a section of up to three lines above the
routing signals:

    Related memories (matched to this wake from your memory store; `mem show <name>` prints one whole; ...):
    - 2026-08-28-..._gh-write-for-audel [fact, 1w]: GitHub write for audel on this box: gh is logged in as headlong42 ...

How a line is chosen:

- The query is the wake's own material: the routing signals (a pending
  request's text, the goal-review nudge) and the content of the last three
  stream steps. Words the prompt template itself contributes are stripped
  first (`_RELATED_STOPWORDS` in thinkers/_lib/common.sh); without that,
  every timer wake matched the same hub notes on "mind", "pick", "signals".
- `mem prefilter` ranks the store with BM25 (bin/mem `mem_prefilter`), the
  same stage a `mem search` runs before the model. The earlier score was
  IDF times log(count) with no length term, and it ranked the same three
  long architecture notes first for every query in a trial on Audel's last
  eight wakes. With BM25, two of three picks were on topic per wake, none
  repeated across the eight, and a pending PR request pulled the note that
  says the box's GitHub login is pull-only.
- Skipped: memories written in the last day (they are in the stream
  already) and the names shown in the previous wake (kept in the monolith's
  state file as `related_prev`), so an open thread does not repeat the same
  three lines every wake.
- No model call. About 500 bytes a wake.

Knobs: `MONOLITH_RELATED_MEMORIES` (lines, default 3, 0 disables),
`RELATED_FRESH_S` (skip memories newer than this many seconds, default a day;
0 disables age exclusion while keeping the previous-wake exclusion). Invalid
values produce a warning and use the one-day default. Creation dates use the
local time written by `mem`; missing or invalid dates fall back to file mtime.

What it does not do: associative recall of a memory whose relevance the
current words do not carry. That needs the model stage of the search or the
bundled retrieval thinker, and is not claimed here.

## Goals

The active-goals section (`get_goals`) now shows every goal-family memory:
goal, intention, objective, todo. Newest first, each with its type and age,
capped at `GOALS_MAX` (8) lines plus a count of the rest. A memory with
`until: YYYY-MM-DD` in its frontmatter drops out after that date;
`mem add --type todo --until 2026-09-10 "..."` writes one.

Once every `MONOLITH_GOAL_REVIEW_DAYS` (7), a routing hint asks for the
goals function with the housekeeping spelled out: forget what is done, edit
duplicates into one, date open todos. The goals entry in the menu says the
same. The last hint time is `goal_review_at` in the state file.

## Measuring whether it helps

`deploy/scripts/audel-metrics` gains a "related memories" section, computed
from the log with no extra instrumentation, because the prompt step carries
the rendered section:

- wakes: prompts that carried the section; shown: names listed.
- distinct: distinct names that day.
- repeat: share of names also shown the wake before. High repeat with low
  fetched means the ranking is stuck on hub documents.
- fetched: share of names the run then opened, meaning any later command in
  that run names the memory (mem show, cat of its file). The click-through
  rate. Edits and forgets do not count as a fetch.
- fixed: share edited or forgotten within a day of being shown. The trial
  surfaced two out-of-date architecture notes; the useful reaction is to fix
  them, and this counts it.
- searches: `mem search` commands that day, as context.
- B/wake: section bytes per wake, so the cost stays next to the benefit.

`deploy/scripts/audel-recall-judge [N]` samples the last N sections on the
box, gives the fast model each wake's material and the lines shown, and asks
for a 0 to 2 score per line. It separates a relevant memory the mind ignored
from an irrelevant one, which the counters cannot.

A week after deploy: fetched above about a fifth, repeat falling, judged
mean above 1, bytes flat. Low fetched and low judged relevance means the
ranking is wrong. High judged relevance with low fetched means the one-line
summaries are enough.

## Deploy notes

No restart. Confirm a new prompt step carries "Related memories (" and the
state file gains `related_prev`. Run audel-metrics on the deploy day for the
baseline (the section will show zero for earlier days). The goal-review hint
fires on the first wake after deploy.

## Left open

- Mention rate (the final quoting a surfaced memory without opening it) is
  not measured; names are slugs and rarely quoted.
- The kernel chat skill and the disabled goals-manager thinker still exist
  on disk.
- Stale memories will now be visible; the weekly cleanup wakeup from the
  09-04 discussion is not built.
