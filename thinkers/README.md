# thinkers/

The thought processes that make up a mind. Each subdirectory is one
thinker: a `step` executable that produces the next thought, and a
`subscriptions.jsonl` that says which trajectory entries wake it. The
`thinkers` dispatcher in [bin/](../bin/) runs them.

- `monolith/` is the main mind loop, with its prompt in `prompt.md`, or
  `prompt-project.md` in project mode (design/long_autonomy.md).
- `responder/` handles fast chat replies.
- `retrieval/` is passive memory recall (memories that share words with
  the current step surface as observations). Ships disabled: enable it in
  the dashboard or delete the identity's `thinkers/retrieval/disabled`
  marker. Updates preserve that per-identity choice.
- `_lib/` holds shell helpers shared by the thinkers; `_lib/project.sh` is
  project mode (rituals, guard, budget, commits).

Code here counts against the under-10K-lines core (`cloc bin/ thinkers/`).
