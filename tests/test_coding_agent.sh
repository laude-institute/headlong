#!/usr/bin/env bash
# tests/test_coding_agent.sh - Phase 1 delegation lifecycle without API calls.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s%s\n' "$1" "${2:+ - $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
is() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/opencode-fake" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '{"event":"fake-start","secret":"%s"}\n' "${OPENROUTER_API_KEY:-}"
case "${FAKE_OPENCODE_MODE:-success}" in
    success)
        printf 'implemented\n' > delegated.txt
        printf '{"event":"fake-complete"}\n'
        ;;
    verify-fail)
        printf 'broken\n' > delegated.txt
        printf '{"event":"fake-complete"}\n'
        ;;
    commit-hook-dirty)
        printf 'implemented\n' > delegated.txt
        hook=$(git rev-parse --git-path hooks/post-commit)
        printf '#!/bin/sh\nprintf "late edit\\n" >> delegated.txt\n' > "$hook"
        chmod +x "$hook"
        ;;
    executor-125)
        printf 'implemented\n' > delegated.txt
        exit 125
        ;;
    executor-timeout)
        printf 'implemented\n' > delegated.txt
        (sleep 3; printf 'leaked\n' > "$FAKE_TIMEOUT_MARKER") &
        wait
        ;;
    executor-timeout-stubborn-child)
        printf 'implemented\n' > delegated.txt
        exec python3 - "$FAKE_TIMEOUT_MARKER" <<'PY_CHILD'
import signal, subprocess, sys, time
# The descendant inherits ignored TERM before it can race with the deadline.
signal.signal(signal.SIGTERM, signal.SIG_IGN)
subprocess.Popen([sys.executable, "-c",
                  "import pathlib, sys, time; time.sleep(4); pathlib.Path(sys.argv[1]).write_text('leaked')",
                  sys.argv[1]])
signal.signal(signal.SIGTERM, signal.SIG_DFL)
time.sleep(30)
PY_CHILD
        ;;
    source-commit|source-dirty|source-untracked|source-index|source-branch)
        printf 'implemented\n' > delegated.txt
        case "$FAKE_OPENCODE_MODE" in
            source-commit)
                printf 'committed change\n' > "$FAKE_SOURCE_REPO/original.txt"
                git -C "$FAKE_SOURCE_REPO" add original.txt
                git -C "$FAKE_SOURCE_REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm changed
                ;;
            source-dirty) printf 'different dirty content\n' > "$FAKE_SOURCE_REPO/original.txt" ;;
            source-untracked) printf 'different untracked content\n' > "$FAKE_SOURCE_REPO/untracked.txt" ;;
            source-index) git -C "$FAKE_SOURCE_REPO" add original.txt ;;
            source-branch) git -C "$FAKE_SOURCE_REPO" checkout -qb another-branch ;;
        esac
        ;;
    executor-fail)
        printf 'partial\n' > delegated.txt
        printf 'fake executor failed intentionally\n' >&2
        exit 17
        ;;
esac
FAKE
chmod +x "$WORK/bin/opencode-fake"

new_fixture() {
    local name="$1"
    local dir="$WORK/$name/repo" trajectories="$WORK/$name/trajectories"
    mkdir -p "$dir" "$trajectories"
    git -C "$dir" init -q
    printf 'source\n' > "$dir/original.txt"
    printf '__pycache__/\n' > "$dir/.gitignore"
    git -C "$dir" add original.txt .gitignore
    git -C "$dir" -c user.name=Test -c user.email=test@example.invalid commit -qm base
    FIXTURE_REPO="$dir"
    FIXTURE_TRAJ_DIR="$trajectories"
    FIXTURE_PARENT=$(TRAJ_DIR="$trajectories" traj new --slug parent | head -n 1)
    FIXTURE_BASE=$(git -C "$dir" rev-parse HEAD)
}

run_case() {
    local name="$1" mode="$2"
    local verify_command="${3:-test \"\$(cat delegated.txt)\" = implemented && printf \"verified\\n\"}" timeout="${4:-300}"
    new_fixture "$name"
    case "$mode" in
        source-dirty|source-index|dirty-unchanged) printf 'initial dirty content\n' > "$FIXTURE_REPO/original.txt" ;;
        source-untracked) printf 'initial untracked content\n' > "$FIXTURE_REPO/untracked.txt" ;;
    esac
    [[ "$mode" == dirty-unchanged ]] && mode=success
    local out="$WORK/$name/artifacts"
    CASE_JSON=$(FAKE_OPENCODE_MODE="$mode" FAKE_SOURCE_REPO="$FIXTURE_REPO" FAKE_TIMEOUT_MARKER="$WORK/timeout-leaked" OPENROUTER_API_KEY='test-secret-value' \
        coding-agent --repo "$FIXTURE_REPO" \
        --task 'Create delegated.txt containing exactly implemented.' \
        --verify "$verify_command" --timeout "$timeout" \
        --backend-bin "$WORK/bin/opencode-fake" --model fake/provider \
        --out "$out" --traj-dir "$FIXTURE_TRAJ_DIR" --parent-traj "$FIXTURE_PARENT" 2>"$WORK/$name/cli.stderr")
    CASE_RC=$?
    CASE_OUT="$out"
    CASE_CHILD=$(printf '%s' "$CASE_JSON" | jq -r '.child_traj')
    CASE_CHILD_FILE=$(TRAJ_DIR="$FIXTURE_TRAJ_DIR" TRAJ_ID="$CASE_CHILD" traj path)
    CASE_PARENT_FILE=$(TRAJ_DIR="$FIXTURE_TRAJ_DIR" TRAJ_ID="$FIXTURE_PARENT" traj path)
}

# A. Passing executor + independent check produces a retained candidate.
run_case success success
is "success: CLI exits zero" 0 "$CASE_RC"
is "success: result status is candidate" candidate "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
is "success: candidate true, accepted false" 'true false' "$(printf '%s' "$CASE_JSON" | jq -r '[.candidate,.accepted] | join(" ")')"
is "success: executor and verification pass" '0 0' "$(printf '%s' "$CASE_JSON" | jq -r '[.executor_exit_status,.verification_exit_status] | join(" ")')"
check "success: parent trajectory exists" test -f "$CASE_PARENT_FILE"
check "success: child trajectory exists" test -f "$CASE_CHILD_FILE"
is "success: child has delegation and result" 'delegation delegation-result' \
    "$(jq -r 'select(.type == "delegation" or .type == "delegation-result") | .type' "$CASE_CHILD_FILE" | tr '\n' ' ' | sed 's/ $//')"
is "success: parent has fork and merge lineage" 'fork merge' \
    "$(jq -r 'select(.type == "fork" or .type == "merge") | .type' "$CASE_PARENT_FILE" | tr '\n' ' ' | sed 's/ $//')"
is "success: merge points to child" "$CASE_CHILD" "$(jq -r 'select(.type == "merge") | .from_traj' "$CASE_PARENT_FILE")"
check "success: isolated worktree contains executor edit" test "$(cat "$CASE_OUT/worktree/delegated.txt")" = implemented
check "success: independent verification output retained" grep -qx verified "$CASE_OUT/verification.stdout"
check "success: candidate commit differs from base" test "$(printf '%s' "$CASE_JSON" | jq -r '.candidate_commit')" != "$FIXTURE_BASE"
check "success: candidate patch retained" test -s "$CASE_OUT/candidate.patch"
check "success: source checkout did not receive delegated file" test ! -e "$FIXTURE_REPO/delegated.txt"
is "success: source HEAD remains base" "$FIXTURE_BASE" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
is "success: source status remains clean" '' "$(git -C "$FIXTURE_REPO" status --porcelain)"
check "success: trajectory DAG validates" env TRAJ_DIR="$FIXTURE_TRAJ_DIR" TRAJ_ID="$FIXTURE_PARENT" traj check -r
check "success: provider key redacted from executor log" bash -c '! grep -qF "$2" "$1"' _ "$CASE_OUT/executor.stdout" test-secret-value
check "success: provider key absent from trajectories" bash -c '! grep -R -qF "$2" "$1"' _ "$FIXTURE_TRAJ_DIR" test-secret-value

# B. A mechanically failing change is retained but is not a candidate.
run_case verification_failure verify-fail
check "verification failure: CLI is nonzero" test "$CASE_RC" -ne 0
is "verification failure: status recorded" verification_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
is "verification failure: check exit recorded" 1 "$(printf '%s' "$CASE_JSON" | jq -r '.verification_exit_status')"
is "verification failure: candidate false and accepted false" 'false false' "$(printf '%s' "$CASE_JSON" | jq -r '[.candidate,.accepted] | join(" ")')"
check "verification failure: isolated edit remains inspectable" test "$(cat "$CASE_OUT/worktree/delegated.txt")" = broken
check "verification failure: source checkout unchanged" test ! -e "$FIXTURE_REPO/delegated.txt"
is "verification failure: source HEAD remains base" "$FIXTURE_BASE" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
is "verification failure: parent receives useful status" verification_failed "$(jq -r 'select(.type == "merge") | .delegation_status' "$CASE_PARENT_FILE")"
check "verification failure: trajectory DAG validates" env TRAJ_DIR="$FIXTURE_TRAJ_DIR" TRAJ_ID="$FIXTURE_PARENT" traj check -r

# C. Executor failure is recorded even though it left a partial isolated edit.
run_case executor_failure executor-fail
is "executor failure: CLI preserves executor exit" 17 "$CASE_RC"
is "executor failure: status recorded" executor_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
is "executor failure: executor exit recorded" 17 "$(printf '%s' "$CASE_JSON" | jq -r '.executor_exit_status')"
is "executor failure: candidate false and accepted false" 'false false' "$(printf '%s' "$CASE_JSON" | jq -r '[.candidate,.accepted] | join(" ")')"
check "executor failure: stderr artifact is useful" grep -q 'failed intentionally' "$CASE_OUT/executor.stderr"
check "executor failure: partial edit remains isolated" test "$(cat "$CASE_OUT/worktree/delegated.txt")" = partial
check "executor failure: source checkout unchanged" test ! -e "$FIXTURE_REPO/delegated.txt"
is "executor failure: parent receives useful status" executor_failed "$(jq -r 'select(.type == "merge") | .delegation_status' "$CASE_PARENT_FILE")"
check "executor failure: trajectory DAG validates" env TRAJ_DIR="$FIXTURE_TRAJ_DIR" TRAJ_ID="$FIXTURE_PARENT" traj check -r

# D. Real exit 125 must not be mistaken for the initial not-run sentinel.
run_case executor_125 executor-125
is "exit 125: executor status preserved" 125 "$(printf '%s' "$CASE_JSON" | jq -r '.executor_exit_status')"
is "exit 125: CLI preserves executor failure" 125 "$CASE_RC"
is "exit 125: executor is not a candidate" executor_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
run_case verify_125 success 'exit 125'
is "exit 125: verifier status preserved" 125 "$(printf '%s' "$CASE_JSON" | jq -r '.verification_exit_status')"
is "exit 125: verifier is not a candidate" verification_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"

# E. Reject checks that attest to files different from the recorded commit.
run_case verify_repairs verify-fail 'printf "fixed\n" > delegated.txt; test "$(cat delegated.txt)" = fixed'
is "verification mutation: passing command is still recorded" 0 "$(printf '%s' "$CASE_JSON" | jq -r '.verification_exit_status')"
is "verification mutation: candidate rejected" verification_changed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
is "verification mutation: CLI fails" 1 "$CASE_RC"
is "verification mutation: mismatch recorded" false "$(printf '%s' "$CASE_JSON" | jq -r '.verification_checkout_unchanged')"
is "verification mutation: original candidate is inspectable" broken "$(git -C "$CASE_OUT/worktree" show HEAD:delegated.txt)"
is "verification mutation: mutated worktree is retained" fixed "$(cat "$CASE_OUT/worktree/delegated.txt")"
is "verification mutation: parent sees rejection" verification_changed "$(jq -r 'select(.type == "merge") | .delegation_status' "$CASE_PARENT_FILE")"
check "verification mutation: DAG validates" env TRAJ_DIR="$FIXTURE_TRAJ_DIR" TRAJ_ID="$FIXTURE_PARENT" traj check -r
run_case verify_commits success 'printf "fixed\n" > delegated.txt; git add delegated.txt; git -c user.name=Test -c user.email=test@example.invalid commit -qm repaired'
is "verification commit: clean status does not hide changed HEAD" verification_changed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
run_case verify_untracked success 'printf "test dependency\n" > dependency.txt'
is "verification new files: non-ignored dependency rejects candidate" verification_changed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
run_case verify_cache success 'mkdir __pycache__; printf "cache\n" > __pycache__/cache.pyc'
is "verification cache: ignored artifacts are allowed" candidate "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
is "verification cache: checkout attestation remains true" true "$(printf '%s' "$CASE_JSON" | jq -r '.verification_checkout_unchanged')"

run_case commit_hook_dirty commit-hook-dirty true
is "commit hook: dirty candidate rejected before attestation" candidate_commit_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
is "commit hook: original committed value retained" implemented "$(git -C "$CASE_OUT/worktree" show HEAD:delegated.txt)"

# F. Content/HEAD/index/branch invariants, including pre-existing dirty work.
for mode in source-commit source-dirty source-untracked source-index source-branch; do
    run_case "$mode" "$mode"
    is "$mode: candidate rejected" source_changed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
    is "$mode: unchanged flag is false" false "$(printf '%s' "$CASE_JSON" | jq -r '.source_checkout_unchanged')"
    is "$mode: CLI fails" 1 "$CASE_RC"
    is "$mode: parent receives rejection" source_changed "$(jq -r 'select(.type == "merge") | .delegation_status' "$CASE_PARENT_FILE")"
done
run_case dirty_unchanged dirty-unchanged
is "dirty source: unchanged dirty checkout remains supported" candidate "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
is "dirty source: content remains untouched" 'initial dirty content' "$(cat "$FIXTURE_REPO/original.txt")"

# G. Deadlines stop the tool process group, retain evidence and merge failure.
run_case executor_timeout executor-timeout 'test -f delegated.txt' 1
is "executor timeout: exit 124 recorded" 124 "$(printf '%s' "$CASE_JSON" | jq -r '.executor_exit_status')"
is "executor timeout: candidate rejected" executor_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
check "executor timeout: diagnostic retained" grep -q 'deadline exceeded' "$CASE_OUT/executor.stderr"
run_case verification_timeout success 'sleep 5' 1
is "verification timeout: exit 124 recorded" 124 "$(printf '%s' "$CASE_JSON" | jq -r '.verification_exit_status')"
is "verification timeout: candidate rejected" verification_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
check "timeout: descendant did not survive to write" test ! -e "$WORK/timeout-leaked"
check "timeout: DAG validates" env TRAJ_DIR="$FIXTURE_TRAJ_DIR" TRAJ_ID="$FIXTURE_PARENT" traj check -r

# Reaping a leader must not skip KILL for descendants that ignored TERM.
run_case stubborn_child executor-timeout-stubborn-child 'test -f delegated.txt' 1
is "stubborn child: timeout exit preserved" 124 "$(printf '%s' "$CASE_JSON" | jq -r '.executor_exit_status')"
is "stubborn child: candidate rejected" executor_failed "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
sleep 3
check "stubborn child: killed after leader exited" test ! -e "$WORK/timeout-leaked"

# H. No-op and artifact reuse must not look like new accepted work.
run_case no_changes no-op true
is "no changes: not a candidate" no_changes "$(printf '%s' "$CASE_JSON" | jq -r '.status')"
reuse_before=$(cat "$CASE_OUT/executor.stdout")
coding-agent --repo "$FIXTURE_REPO" --task anything --verify true --out "$CASE_OUT" >"$WORK/reuse.stdout" 2>"$WORK/reuse.stderr"
is "artifact reuse: refused before overwriting evidence" 2 "$?"
is "artifact reuse: old executor log preserved" "$reuse_before" "$(cat "$CASE_OUT/executor.stdout")"

# I. Standalone runs must consume all of traj new's output under pipefail.
standalone=$(env -u TRAJ_DIR -u TRAJ_ID FAKE_OPENCODE_MODE=success \
    coding-agent --repo "$FIXTURE_REPO" --task 'Create delegated.txt' \
    --verify 'test -f delegated.txt' --backend-bin "$WORK/bin/opencode-fake" \
    --out "$WORK/standalone" 2>"$WORK/standalone.stderr")
is "standalone: creates its parent without SIGPIPE" 0 "$?"
is "standalone: candidate returned" candidate "$(printf '%s' "$standalone" | jq -r '.status')"
check "standalone: parent trajectory retained" test -d "$WORK/standalone/trajectories"

# J. Validate deadlines before any run and output placement before forking.
coding-agent --repo "$FIXTURE_REPO" --task anything --verify true --timeout 0 >"$WORK/invalid.stdout" 2>"$WORK/invalid.stderr"
is "invalid deadline: rejected" 2 "$?"
coding-agent --repo "$FIXTURE_REPO" --task anything --verify true --out "$FIXTURE_REPO/artifacts" >"$WORK/placement.stdout" 2>"$WORK/placement.stderr"
is "non-ignored source output: rejected" 2 "$?"
check "non-ignored source output: no worktree created" test ! -e "$FIXTURE_REPO/artifacts/worktree"

# K. A directory-backed gitlink must be fingerprinted or fail closed.
# Load the production function without running the CLI lifecycle.
eval "$(sed -n '/^checkout_fingerprint() {$/,/^}$/p' "$REPO/bin/coding-agent")"
new_fixture submodule_source
submodule_source="$FIXTURE_REPO"
new_fixture submodule_parent
git -C "$FIXTURE_REPO" -c protocol.file.allow=always submodule add -q "$submodule_source" vendor/lib
git -C "$FIXTURE_REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm submodule
before=$(checkout_fingerprint "$FIXTURE_REPO")
is "initialized submodule: initial fingerprint succeeds" 0 "$?"
printf 'working edit\n' >> "$FIXTURE_REPO/vendor/lib/original.txt"
after=$(checkout_fingerprint "$FIXTURE_REPO")
is "initialized submodule: edited fingerprint succeeds" 0 "$?"
check "initialized submodule: content edit changes fingerprint" test "$before" != "$after"

# Custos's repro: metadata is already absent before either snapshot.
rm "$FIXTURE_REPO/vendor/lib/.git"
before=$(checkout_fingerprint "$FIXTURE_REPO" 2>"$WORK/submodule-before.stderr")
is "broken submodule: initial fingerprint fails closed" 1 "$?"
printf 'y\n' >> "$FIXTURE_REPO/vendor/lib/original.txt"
after=$(checkout_fingerprint "$FIXTURE_REPO" 2>"$WORK/submodule-after.stderr")
is "broken submodule: edited fingerprint fails closed" 1 "$?"
is "broken submodule: no initial digest emitted" '' "$before"
is "broken submodule: no edited digest emitted" '' "$after"
check "broken submodule: diagnostic explains failure" grep -q 'submodule directory lacks .git metadata' "$WORK/submodule-before.stderr"
coding-agent --repo "$FIXTURE_REPO" --task anything --verify true \
    --backend-bin "$WORK/bin/opencode-fake" --out "$WORK/broken-submodule-artifacts" \
    >"$WORK/broken-submodule.stdout" 2>"$WORK/broken-submodule.stderr"
is "broken submodule: CLI rejects source snapshot" 2 "$?"
check "broken submodule: CLI reports snapshot failure" grep -q 'could not snapshot source checkout' "$WORK/broken-submodule.stderr"
check "broken submodule: no worktree created" test ! -e "$WORK/broken-submodule-artifacts/worktree"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
