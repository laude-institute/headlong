# Headlong dash (headlong-web)

The dashboard: a web UI for watching a Headlong identity think. It shows the
**mind log** (an identity's root trajectory), the **runs** dispatched by
thinkers, and the **fork tree** of nested shellm sub-runs, with live
updating while the mind is running, plus a chat view, memories, thinker
status, health, and configuration. The construction is a React Router 7
SPA served by a small FastAPI backend that reads trajectory JSONL straight
off disk.

Modeled after the Harbor job viewer: https://github.com/laude-institute/harbor

## Usage

```bash
# Serve the Headlong checkout itself (finds all identity dirs under it)
headlong-web                 # installed on PATH by install.sh; or tools/headlong-web

# Serve any directory containing identity dirs
headlong-web ~/some/dir

# Dev mode: vite dev server (hot reload) + uvicorn --reload
headlong-web --dev

# Options
headlong-web [ROOT] [--port N] [--host H] [--rebuild] [--dev]
```

`ada dash` (the persona command) starts it for you and opens the browser.

Requires [uv](https://docs.astral.sh/uv/) for the backend and a JS package
manager for the frontend — bun, pnpm, or npm, auto-detected in that order
(`bun.lock` is the committed lockfile). Set `HEADLONG_WEB_JS=bun|pnpm|npm`
to force one (`pnpm` works via corepack even when not installed globally).
The first production launch builds the frontend automatically
(`--rebuild` forces it).

Environment: `HEADLONG_WEB_SELF_UPDATE=1` lets the dash pull and restart
itself (used by the systemd unit); `HEADLONG_VAPID_SUB` is the `mailto:`
contact sent with web push notifications. Legacy `SHELLM_*` spellings are
still honored.

## What it shows

- **Home** (`/`) — every identity dir under the root (any directory with an
  `info.txt` containing `root_trajectory=`), grouped by location, with live
  badges and last activity; import/export and the kill switch live here.
- **Talk** (`/talk`, `/talk/<identity>`) — the phone-friendly chat PWA:
  pick an identity and message it directly.
- **Timeline** (`/i/<identity>`) — the identity's activity as lanes per
  thinker, with runs and messages over time.
- **Mind log** (`/i/<identity>/mindlog`) — the root trajectory as a step
  stream:
  - steps colored by type with thinker attribution (`source`) chips;
    machinery steps (no `source`) get a gear glyph
  - inline actor runs grouped into collapsible blocks
    (`shellm-run → reasoning/shell-output → final`), joined to the `action`
    step that triggered them
  - consecutive `idle` steps folded into strips
  - type/source filters (URL-persisted), search, expand-all, and a
    proportional timeline bar (click to jump)
  - fork steps link to child trajectories; write-back thoughts link back
- **Recap** (`/i/<identity>/recap`) — the trajectory summarized into
  themes and episodes (the `recap` tool), incremental or full refresh.
- **Sub-trajectory** (`/i/<identity>/t/<traj_id>`) — drill into forked
  sub-runs (and sub-runs of sub-runs) with breadcrumbs and a lazy fork-tree
  sidebar; blob-spilled stdout/stderr can be loaded in place.
- **Chat** (`/i/<identity>/chat`) — the message steps of the mind log as a
  conversation.
- **Thinkers** (`/i/<identity>/thinkers`) — per-thinker status,
  dispatcher.log parsed into dispatch events, and a tail of each
  `run/logs/*.log`, with start/stop controls.
- **Memories** (`/i/<identity>/memories`) — searchable, type-filtered memory
  cards with frontmatter summaries and dates, plus the full Markdown reader.
- **Health** (`/i/<identity>/health`) — reply latency, stalls, and LLM
  provider health inferred from the mind log.
- **Usage** (`/i/<identity>/usage`) — messages, model calls, tokens and
  cost per UTC day and per model, counted from the mind log and the usage
  ledger (`usage/llm.jsonl`); OpenCode delegations' cost is shown apart.
  With `LLM_SPEND_LIMIT_USD` set, the identity's spend limit, live from
  `llm --spend`; the navbar's `llm` chip turns red when a call is refused
  by it.
- **Config** (`/i/<identity>/config`) — the identity's `.env` (model,
  effort, keys redacted) with an OpenRouter model picker.

## Live updating

A session counts as live when `run/dispatcher.pid` points at a running
process or the mind log was modified in the last 30 seconds. While live,
the frontend polls every 2 seconds (react-query `refetchInterval`) and a
follow pill keeps the view pinned to the newest steps; scrolling up pauses
following.

## Layout

```
web/
├── pyproject.toml        # backend package (fastapi + uvicorn)
├── src/headlong_web/       # FastAPI backend
│   ├── server.py         #   app factory + API endpoints + SPA serving
│   ├── cli.py            #   the headlong-web entry point (build, serve, --dev)
│   ├── discovery.py      #   identity dir scanning
│   ├── trajectory.py     #   JSONL parsing, run grouping, previews, parse cache
│   ├── tree.py           #   fork-tree resolution
│   ├── liveness.py       #   session liveness
│   ├── activity.py       #   working-vs-stalled classification
│   ├── chat.py           #   chat view over the mind log
│   ├── search.py         #   mind-log search
│   ├── logs.py           #   thinker log tails, dispatcher.log parsing
│   ├── thinkers.py       #   per-identity thinker status
│   ├── thinker_sync.py   #   installed vs bundled thinker comparison
│   ├── control.py        #   mutations: shells out to the bash CLIs
│   ├── health.py         #   reply stats;  llm_health.py: provider health
│   ├── envfile.py        #   read/edit identity .env (secrets redacted)
│   ├── env.py            #   HEADLONG_* / SHELLM_* env var resolution
│   ├── openrouter.py     #   model catalog for the config screen
│   ├── push.py           #   web push: VAPID keys, subscriptions, watcher
│   ├── safety.py         #   path containment + name whitelists
│   └── static/           #   built frontend (generated)
├── tests/                # pytest against real repo fixtures
├── design/               # data model and overview notes for the dash
└── viewer/               # React Router 7 SPA (vite, tailwind v4, shadcn/ui)
```

## Development

```bash
headlong-web --dev                 # backend :8080-8089, frontend :5173
cd web && uv run pytest          # backend tests
cd web/viewer && bun run typecheck
```

The backend API is plain JSON under `/api/*` — see `src/headlong_web/server.py`
for the endpoint list. Trajectory semantics (step types, fork/merge links,
blob spillover) follow `design/trajectory_spec.md`.
