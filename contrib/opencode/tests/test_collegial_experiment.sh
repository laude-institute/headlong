#!/usr/bin/env bash
# Fully offline experiment contract, with real coding-agent and trajectory calls.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 "$HERE/experiments/collegial_slugify.py" --out "$WORK/experiment" > "$WORK/result.json"
jq -e '.invocation == "scripted_fixture" and .autonomous == false and .api_calls == 0
       and .initial_status == "candidate" and .initial_review == "rejected"
       and .initial_review_failures > 0 and .revised_status == "candidate"
       and .full_review_cases == 10 and .final_verdict == "ready_for_human_review"
       and .accepted == false and .source_unchanged and .revision_based_on_first_candidate' "$WORK/result.json" >/dev/null
printf 'ok   mechanical pass, semantic rejection, revised candidate, no automatic acceptance\n'
python3 - "$WORK/experiment" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
summary = json.loads((root / 'summary.json').read_text())
files = list((root / 'trajectories').rglob('trajectory.jsonl'))
assert len(files) == 3
parent = next(p for p in files if p.parent.parent == root / 'trajectories')
steps = [json.loads(line) for line in parent.read_text().splitlines()]
assert len([s for s in steps if s['type'] == 'fork']) == 2
assert len([s for s in steps if s['type'] == 'merge']) == 2
rejection = next(s for s in steps if s.get('verdict') == 'rejected')
revision = next(s for s in steps if s.get('verdict') == 'ready_for_human_review')
assert rejection['child_traj'] == summary['initial_child']
assert revision['revision_of'] == summary['initial_child']
assert revision['child_traj'] == summary['revised_child']
assert rejection['candidate_commit'] == json.loads((root/'result-2.json').read_text())['base_commit']
print('ok   parent records rejection and revision with both child references')
PY
