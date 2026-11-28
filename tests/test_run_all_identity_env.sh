#!/usr/bin/env bash
# The suite runner must not pass an activated identity into fixture tests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/suite" "$WORK/app" "$WORK/home" "$WORK/tmp" "$WORK/live/caller"
printf 'name=caller\n' > "$WORK/live/caller/info.txt"
cp -R "$WORK/live" "$WORK/live-before"
# A private suite prevents this test from recursively running itself.
cp "$HERE/run-all.sh" "$WORK/suite/run-all.sh"
cat > "$WORK/suite/test_fixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
fail=0
for name in IDENTITY_NAME IDENTITY_DIR MEM_DIR SKILLS_DIR SKILLS_KERNEL_DIR TRAJ_ID TRAJ_DIR ROOT_TRAJ_ID \
         SHELLM_MODEL THINK_MODEL MONOLITH_REPLY_MODEL HEADLONG_TZ SHELLM_RUNDIR LLM_RUN_ID TMPDIR \
         SHELLM_TRAJ_DIR; do
    if [[ -n "${!name+x}" ]]; then
        printf 'FAIL inherited %s reached the child\n' "$name"
        fail=1
    else
        printf 'ok   %s is unset in the child\n' "$name"
    fi
done
cd "$FIXTURE_APP" || exit 1
identity new alpha >/dev/null || exit 1
if [[ -f .identities/alpha/info.txt ]]; then
    printf 'ok   identity created under the temporary app\n'
else
    printf 'FAIL identity created outside the temporary app\n'
    fail=1
fi
exit "$fail"
FIXTURE

# Do not inherit credentials or other live paths, even when run standalone.
rc=0
env -i HOME="$WORK/home" TMPDIR="$WORK/tmp" \
    PATH="$REPO/bin:$REPO/tools:$PATH" SHELLM_ENV=local \
    FIXTURE_APP="$WORK/app" \
    IDENTITY_NAME=caller IDENTITY_DIR="$WORK/live/caller" \
    MEM_DIR="$WORK/live/caller/memories" \
    SKILLS_DIR="$WORK/live/caller/skills" \
    SKILLS_KERNEL_DIR="$WORK/live/caller/kernel" \
    TRAJ_ID=caller-root TRAJ_DIR="$WORK/live/caller/trajectories" \
    ROOT_TRAJ_ID=caller-root \
    SHELLM_MODEL=wake-model THINK_MODEL=wake-thinker \
    MONOLITH_REPLY_MODEL=wake-reply HEADLONG_TZ=America/Los_Angeles \
    SHELLM_RUNDIR="$WORK/live/run" LLM_RUN_ID=wake-usage TMPDIR="$WORK/tmp/leaked" \
    SHELLM_TRAJ_DIR="$WORK/live/caller/trajectories" \
    bash "$WORK/suite/run-all.sh" || rc=$?

if diff -r "$WORK/live-before" "$WORK/live"; then
    printf 'ok   fake active identity and its parent are unchanged\n'
else
    printf 'FAIL fixture modified the fake active identity or its parent\n'
    rc=1
fi
exit "$rc"
