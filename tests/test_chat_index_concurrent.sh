#!/usr/bin/env bash
# Pause one real history reader after its offset read, let another finish,
# then resume it. A cursor read outside the lock indexes the new row twice.
set -euo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO/bin:$PATH"
WORK=$(mktemp -d)
worker=""
cleanup() {
    if [[ -n "$worker" ]]; then kill "$worker" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
export TRAJ_ID=cafe0000-0000-0000-0000-0000000000ce
export TRAJ_DIR="$WORK/trajectories" IDENTITY_NAME=ada MEM_DIR="$WORK/memories"
export CHATRC="$WORK/chatrc"
mkdir -p "$TRAJ_DIR/$TRAJ_ID" "$MEM_DIR" "$WORK/shim" "$WORK/gate"
trajectory="$TRAJ_DIR/$TRAJ_ID/trajectory.jsonl"
index="$TRAJ_DIR/$TRAJ_ID/messages.jsonl"
stamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"step_id":"header","type":"trajectory","ts":"%s"}\n' "$stamp" > "$trajectory"
message() {
    printf '{"step_id":"%s","type":"message","from":"reader","to":"ada","content":"hello","ts":"%s"}\n' "$1" "$stamp" >> "$trajectory"
}
history() { bash "$REPO/bin/chat" history --with reader --json; }
message m1
history > "$WORK/initial.json"
message m2
export REAL_STAT
REAL_STAT=$(command -v stat)
cat > "$WORK/shim/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if mkdir "$TEST_GATE/once" 2>/dev/null; then
    : > "$TEST_GATE/ready"
    released=false
    for ((attempt=0; attempt<200; attempt++)); do
        if [[ -f "$TEST_GATE/release" ]]; then released=true; break; fi
        sleep 0.05
    done
    "$released" || exit 1
fi
exec "$REAL_STAT" "$@"
EOF
chmod +x "$WORK/shim/stat"
TEST_GATE="$WORK/gate" PATH="$WORK/shim:$PATH" history > "$WORK/first.json" &
worker=$!
ready=false
for ((attempt=0; attempt<100; attempt++)); do
    if [[ -f "$WORK/gate/ready" ]]; then ready=true; break; fi
    sleep 0.05
done
"$ready" || { echo "FAIL reader did not reach the offset boundary"; exit 1; }
history > "$WORK/second.json"
: > "$WORK/gate/release"
wait "$worker"
worker=""
if ! jq -se 'length == 2 and map(.step_id) == ["m1", "m2"]' "$index" >/dev/null; then
    echo "FAIL concurrent readers duplicated or lost an indexed message"
    cat "$index"
    exit 1
fi
read -r offset _ < "$index.offset"
[[ "$offset" == "$(wc -c < "$trajectory" | tr -d ' ')" ]]
[[ ! -d "$index.lock" ]]
echo "ok concurrent history readers index each message once and release the lock"
