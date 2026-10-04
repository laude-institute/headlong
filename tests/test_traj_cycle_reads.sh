#!/usr/bin/env bash
set -euo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export TRAJ_DIR="$WORK/trajectories"
export TRAJ_ID=aaaaaaaa-0000-0000-0000-000000000000
root="$TRAJ_DIR/aaaaaaaa-root"
child="$TRAJ_DIR/bbbbbbbb-child"
mkdir -p "$root" "$child"
printf '{"type":"trajectory","step_id":"root"}\n{"type":"fork","child":"%s","child_ref":"./trajectory.jsonl"}\n' "$TRAJ_ID" > "$root/trajectory.jsonl"
timeout 5 bash "$REPO/bin/traj" cat "$TRAJ_ID" -r --raw > "$WORK/self.jsonl"
[[ "$(jq -s 'map(select(.step_id == "root")) | length' "$WORK/self.jsonl")" == 1 ]]
printf '{"type":"trajectory","step_id":"root"}\n{"type":"fork","child":"bbbbbbbb-0000-0000-0000-000000000000","child_ref":"../bbbbbbbb-child/trajectory.jsonl"}\n' > "$root/trajectory.jsonl"
printf '{"type":"trajectory","step_id":"child"}\n{"type":"fork","child":"%s","child_ref":"../aaaaaaaa-root/trajectory.jsonl"}\n' "$TRAJ_ID" > "$child/trajectory.jsonl"
timeout 5 bash "$REPO/bin/traj" cat "$TRAJ_ID" -r --raw > "$WORK/cycle.jsonl"
jq -se 'map(select(.type == "trajectory") | .step_id) | sort == ["child", "root"]' "$WORK/cycle.jsonl" >/dev/null
echo "ok recursive trajectory reads terminate for relative self and two-node cycles"
printf '{"type":"trajectory","step_id":"root"}\n{"type":"fork","child":"bbbbbbbb-0000-0000-0000-000000000000","child_ref":"../bbbbbbbb-child/trajectory.jsonl"}\n{"type":"fork","child":"bbbbbbbb-0000-0000-0000-000000000000","child_ref":"../bbbbbbbb-child/trajectory.jsonl"}\n' > "$root/trajectory.jsonl"
printf '{"type":"trajectory","step_id":"child"}\n' > "$child/trajectory.jsonl"
timeout 5 bash "$REPO/bin/traj" cat "$TRAJ_ID" -r --raw > "$WORK/shared.jsonl"
[[ "$(jq -s 'map(select(.step_id == "child")) | length' "$WORK/shared.jsonl")" == 2 ]]
echo "ok shared children remain readable through separate fork branches"
