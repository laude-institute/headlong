#!/usr/bin/env bash
set -uo pipefail

# coding-agent - run a bounded coding task on an isolated candidate branch.

usage() {
    cat <<'EOF'
Usage:
  coding-agent --repo DIR --task TEXT --verify COMMAND [options]
  coding-agent --repo DIR --task-file FILE --verify COMMAND [options]

Options:
  --repo DIR           Git checkout whose HEAD is the candidate base
  --task TEXT          Bounded implementation task
  --task-file FILE     Read the task from a file
  --verify COMMAND     Independent verification command, run with bash in the worktree
  --backend NAME       Coding backend (default: opencode)
  --backend-bin PATH   Backend executable (default: CODING_AGENT_OPENCODE_BIN or opencode)
  --model MODEL        Backend model (default: CODING_AGENT_MODEL or backend config)
  --out DIR            New/empty artifacts directory, outside source or Git-ignored
  --timeout SECONDS    Deadline per executor/check, positive integer (default: 300)
  --traj-dir DIR       Headlong trajectories directory (default: TRAJ_DIR)
  --parent-traj ID     Parent trajectory (default: TRAJ_ID)
  -h, --help           Show this help

If no trajectory is supplied, a standalone parent trajectory is created under
OUT/trajectories. Source changes and verification mutations reject the result.
Checks cover HEAD, branch, index, tracked files and non-ignored untracked files;
ignored files are outside this integrity check. This is not an OS sandbox.
Passing verification
produces a candidate only; this command never merges, cherry-picks, pushes, or
deploys it.
EOF
}

die() { printf 'coding-agent: error: %s\n' "$*" >&2; exit 2; }

redact_file() {
    local file="$1" name value
    [[ -f "$file" ]] || return 0
    for name in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY LLM_API_KEY; do
        value="${!name:-}"
        [[ -n "$value" ]] || continue
        SECRET_VALUE="$value" perl -pi -e '
            BEGIN { $secret = $ENV{SECRET_VALUE}; }
            s/\Q$secret\E/<redacted-api-key>/g if length($secret);
        ' "$file" 2>/dev/null || true
    done
}

# Content-based state, not status text: dirty files may change without changing
# their status, and a clean checkout may move to another commit. Ignore runtime
# artifacts excluded by Git, but always hash tracked files (even ignored ones).
checkout_fingerprint() {
    python3 - "$1" <<'PY_STATE'
import hashlib, os, stat, subprocess, sys

def snapshot(root):
    root = os.fsencode(root)
    def git(*args):
        return subprocess.check_output([b"git", b"-C", root, *[os.fsencode(a) for a in args]])
    digest = hashlib.sha256()
    def add(value):
        digest.update(str(len(value)).encode() + b":" + value)
    add(git("rev-parse", "HEAD"))
    add(git("rev-parse", "--symbolic-full-name", "HEAD"))
    index = git("ls-files", "--stage", "-z")
    add(index)
    entries = {}
    for record in index.split(b"\0"):
        if record:
            meta, path = record.split(b"\t", 1)
            entries[path] = meta.split()[0]
    for path in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if path:
            entries.setdefault(path, b"untracked")
    for path, mode in sorted(entries.items()):
        add(path)
        full = os.path.join(root, path)
        try:
            st = os.lstat(full)
        except FileNotFoundError:
            add(b"missing")
            continue
        add(str(stat.S_IFMT(st.st_mode)).encode())
        add(str(stat.S_IMODE(st.st_mode)).encode())
        if stat.S_ISLNK(st.st_mode):
            add(os.readlink(full))
        elif stat.S_ISREG(st.st_mode):
            content = hashlib.sha256()
            with open(full, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    content.update(chunk)
            add(content.digest())
        elif mode == b"160000" and stat.S_ISDIR(st.st_mode):
            # Without metadata Git may discover the parent checkout instead.
            if not os.path.exists(os.path.join(full, b".git")):
                raise RuntimeError("submodule directory lacks .git metadata: " + os.fsdecode(path))
            add(snapshot(full).encode())
        else:
            raise RuntimeError("unsupported file type in checkout")
    return digest.hexdigest()
try:
    print(snapshot(sys.argv[1]))
except Exception as e:
    print("coding-agent: cannot fingerprint checkout: " + str(e), file=sys.stderr)
    sys.exit(1)
PY_STATE
}

# Settle ordinary descendants after every phase, including successful exit.
# Reserve 124 for a deadline; preserve real exit codes, including 125.
run_bounded() {
    local input_file="$1"
    shift
    python3 - "$timeout_seconds" "$input_file" "$@" <<'PY_DEADLINE'
import os, signal, subprocess, sys, time
try:
    child = subprocess.Popen(sys.argv[3:], start_new_session=True,
                             stdin=open(sys.argv[2], "rb") if sys.argv[2] else subprocess.DEVNULL)
except OSError as e:
    print("coding-agent: " + str(e), file=sys.stderr)
    sys.exit(127)
try:
    code = child.wait(timeout=int(sys.argv[1]))
except subprocess.TimeoutExpired:
    print("coding-agent: deadline exceeded after " + sys.argv[1] + " seconds", file=sys.stderr)
    code = 124
finally:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        # Darwin rejects killpg on a zombie-only group with EPERM. Reap an
        # exited leader first, but still signal the group: descendants may live.
        child.poll()
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        if sig == signal.SIGTERM:
            time.sleep(1)
    child.wait()
sys.exit(code if code >= 0 else 128 - code)
PY_DEADLINE
}

repo=""
task=""
task_file=""
verify=""
backend="${CODING_AGENT_BACKEND:-opencode}"
backend_bin=""
model="${CODING_AGENT_MODEL:-}"
out=""
timeout_seconds="${CODING_AGENT_TIMEOUT:-300}"
traj_dir="${TRAJ_DIR:-}"
parent_traj="${TRAJ_ID:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        repo="${2:?--repo requires DIR}"; shift 2 ;;
        --task)        task="${2:?--task requires TEXT}"; shift 2 ;;
        --task-file)   task_file="${2:?--task-file requires FILE}"; shift 2 ;;
        --verify)      verify="${2:?--verify requires COMMAND}"; shift 2 ;;
        --backend)     backend="${2:?--backend requires NAME}"; shift 2 ;;
        --backend-bin) backend_bin="${2:?--backend-bin requires PATH}"; shift 2 ;;
        --model)       model="${2:?--model requires MODEL}"; shift 2 ;;
        --out)         out="${2:?--out requires DIR}"; shift 2 ;;
        --timeout)     timeout_seconds="${2:?--timeout requires SECONDS}"; shift 2 ;;
        --traj-dir)    traj_dir="${2:?--traj-dir requires DIR}"; shift 2 ;;
        --parent-traj) parent_traj="${2:?--parent-traj requires ID}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown argument: $1" ;;
    esac
done

[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
[[ -n "$repo" ]] || die "--repo is required"
[[ -n "$verify" ]] || die "--verify is required"
if [[ -n "$task" && -n "$task_file" ]]; then
    die "use only one of --task or --task-file"
fi
if [[ -n "$task_file" ]]; then
    [[ -f "$task_file" ]] || die "task file not found: $task_file"
    [[ -s "$task_file" ]] || die "task file is empty"
fi
[[ -n "$task" || -n "$task_file" ]] || die "--task or --task-file is required"
[[ "$backend" == "opencode" ]] || die "unsupported backend '$backend' (Phase 1 supports opencode)"
command -v git >/dev/null 2>&1 || die "git is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v perl >/dev/null 2>&1 || die "perl is required"
traj_bin=$(command -v traj 2>/dev/null || true)
[[ -n "$traj_bin" ]] || die "traj is required"

repo=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) \
    || die "not a Git checkout: $repo"
repo=$(cd "$repo" && pwd -P) || die "could not resolve repository"
base_commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null) \
    || die "repository has no HEAD commit: $repo"
source_before=$(checkout_fingerprint "$repo") || die "could not snapshot source checkout"

if [[ -z "$out" ]]; then
    out=$(mktemp -d "${TMPDIR:-/tmp}/headlong-coding-agent.XXXXXX") \
        || die "could not create output directory"
else
    if [[ -d "$out" && -n "$(ls -A "$out")" ]]; then
        die "output directory must be empty: $out"
    fi
    mkdir -p "$out" || die "could not create output directory: $out"
fi
out=$(cd "$out" 2>/dev/null && pwd -P) || die "could not resolve output directory: $out"

if [[ -n "$task_file" ]]; then
    cp "$task_file" "$out/task.md" || die "could not retain task file"
else
    printf '%s' "$task" > "$out/task.md"
fi
task_file="$out/task.md"

case "$out/" in
    "$repo/"*) git -C "$repo" check-ignore -q -- "$out/" \
        || die "output directory inside source must be Git-ignored" ;;
esac

if [[ -z "$traj_dir" && -z "$parent_traj" ]]; then
    traj_dir="$out/trajectories"
    mkdir -p "$traj_dir" || die "could not create trajectory directory"
    # Read the whole response: head -n 1 can SIGPIPE traj under pipefail.
    parent_output=$(TRAJ_DIR="$traj_dir" "$traj_bin" new --slug coding-agent-parent) \
        || die "could not create standalone parent trajectory"
    parent_traj="${parent_output%%$'\n'*}"
elif [[ -z "$traj_dir" || -z "$parent_traj" ]]; then
    die "trajectory requires both --traj-dir and --parent-traj (or TRAJ_DIR and TRAJ_ID)"
fi

child_traj=$(TRAJ_DIR="$traj_dir" TRAJ_ID="$parent_traj" "$traj_bin" fork --slug coding-agent) \
    || die "could not fork child trajectory from $parent_traj"
child_file=$(TRAJ_DIR="$traj_dir" TRAJ_ID="$child_traj" "$traj_bin" path 2>/dev/null || true)
child_ref="${child_file#$traj_dir/}"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
branch="headlong-candidate/${base_commit:0:12}-${stamp}-$$"
worktree="$out/worktree"
executor_stdout="$out/executor.stdout"
executor_stderr="$out/executor.stderr"
verification_stdout="$out/verification.stdout"
verification_stderr="$out/verification.stderr"
patch_file="$out/candidate.patch"

delegation=$(jq -nc \
    --rawfile task "$task_file" --arg backend "$backend" --arg model "$model" \
    --arg repo "$repo" --arg base "$base_commit" --arg verify "$verify" \
    --arg worktree "$worktree" --arg branch "$branch" --arg out "$out" \
    --arg parent "$parent_traj" --arg child "$child_traj" --argjson timeout "$timeout_seconds" \
    '{type:"delegation", task:$task, backend:$backend,
      base_commit:$base, verification_command:$verify, repository:$repo,
      worktree:$worktree, candidate_branch:$branch, artifact_dir:$out,
      parent_traj:$parent, child_traj:$child, timeout_seconds:$timeout}
     + (if $model == "" then {} else {model:$model} end)')
printf '%s' "$delegation" | TRAJ_DIR="$traj_dir" TRAJ_ID="$child_traj" "$traj_bin" append >/dev/null \
    || die "could not append delegation step"

worktree_rc=0
git -C "$repo" worktree add -b "$branch" "$worktree" "$base_commit" \
    >"$out/worktree.stdout" 2>"$out/worktree.stderr" || worktree_rc=$?

executor_rc=125
commit_rc=0
verification_rc=125
candidate_commit=""
has_changes=false
verification_unchanged=false
verification_before=""
verification_after=""
integrity_rc=0

if [[ "$worktree_rc" -eq 0 ]]; then
    if [[ -z "$backend_bin" ]]; then
        backend_bin="${CODING_AGENT_OPENCODE_BIN:-opencode}"
    fi
    resolved_backend=$(command -v "$backend_bin" 2>/dev/null || true)
    if [[ -z "$resolved_backend" && -x "$backend_bin" ]]; then
        resolved_backend="$backend_bin"
    fi

    if [[ -z "$resolved_backend" ]]; then
        printf 'OpenCode executable not found: %s\n' "$backend_bin" >"$executor_stderr"
        : >"$executor_stdout"
        executor_rc=127
    else
        {
            printf '%s\n\n' 'Implement this bounded software-engineering task in the current Git worktree:'
            cat "$task_file"
            printf '\n\nAcceptance criteria are evaluated independently after you stop with:\n%s\n' "$verify"
            printf '%s\n' 'You may edit files and run tests in this worktree. Do not access files outside' 'the current worktree. Do not push, deploy, merge, or modify another checkout.' 'Finish after producing the best implementation you can; do not merely propose it.'
        } > "$out/executor.prompt"
        model_args=()
        [[ -n "$model" ]] && model_args=(--model "$model")
        # Inline config has higher precedence than project config. Keep the
        # caller's provider/model settings, but make the executor's filesystem
        # boundary and no-push/no-subagent policy non-overridable by a checkout.
        # The value remains in the process environment, never argv or logs.
        opencode_guard=$(printf '%s' "${OPENCODE_CONFIG_CONTENT:-{}}" | jq -c '
            (if type == "object" then . else {} end) as $base
            | ($base.permission
               | if type == "object" then . else {} end) as $permission
            | ($permission.bash
               | if type == "object" then . else {} end) as $bash
            | $base * {
                share: "disabled",
                permission: ($permission * {
                    external_directory: "deny",
                    task: "deny",
                    bash: ($bash * {
                        "git push*": "deny",
                        "git merge*": "deny",
                        "git cherry-pick*": "deny"
                    })
                })
              }' 2>/dev/null) || opencode_guard='{"share":"disabled","permission":{"external_directory":"deny","task":"deny","bash":{"git push*":"deny","git merge*":"deny","git cherry-pick*":"deny"}}}'
        executor_rc=0
        (
            cd "$worktree" || exit 125
            unset HEADLONG_HOME SHELLM_HOME SHELLM_CONF_DIR IDENTITY_DIR MEM_DIR SKILLS_DIR \
                SKILLS_KERNEL_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID CHATRC
            OPENCODE_CONFIG_CONTENT="$opencode_guard" \
                run_bounded "$out/executor.prompt" "$resolved_backend" --pure run --format json \
                "${model_args[@]+"${model_args[@]}"}"
        ) >"$executor_stdout" 2>"$executor_stderr" || executor_rc=$?
    fi
    redact_file "$executor_stdout"
    redact_file "$executor_stderr"

    if [[ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]]; then
        git -C "$worktree" add -A >/dev/null 2>&1 || commit_rc=$?
        if [[ "$commit_rc" -eq 0 ]]; then
            git -C "$worktree" -c user.name='Headlong Coding Agent' \
                -c user.email='coding-agent@headlong.local' \
                commit -m 'Candidate from delegated coding task' \
                >"$out/commit.stdout" 2>"$out/commit.stderr" || commit_rc=$?
        fi
    fi

    # Hooks may leave edits/new files after a successful commit. Do not attest
    # to an already-dirty worktree as if it were the recorded candidate.
    if ! git -C "$worktree" diff --quiet -- \
       || ! git -C "$worktree" diff --cached --quiet HEAD -- \
       || [[ -n "$(git -C "$worktree" ls-files --others --exclude-standard)" ]]; then
        commit_rc=1
        printf 'candidate worktree is not clean after commit\n' >>"$out/commit.stderr"
    fi
    result_head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || commit_rc=$?
    if [[ "$result_head" != "$base_commit" ]] \
       || [[ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]]; then
        has_changes=true
    fi
    [[ "$result_head" != "$base_commit" ]] && candidate_commit="$result_head"
    git -C "$worktree" diff --binary "$base_commit" >"$patch_file" 2>"$out/patch.stderr" || true

    verification_before=$(checkout_fingerprint "$worktree") || integrity_rc=$?
    verification_rc=0
    (
        cd "$worktree" || exit 125
        run_bounded "" bash -c "$verify"
    ) >"$verification_stdout" 2>"$verification_stderr" || verification_rc=$?
    verification_after=$(checkout_fingerprint "$worktree") || integrity_rc=$?
    if [[ "$integrity_rc" -eq 0 && "$verification_before" == "$verification_after" ]]; then
        verification_unchanged=true
    fi
    redact_file "$verification_stdout"
    redact_file "$verification_stderr"
else
    : >"$executor_stdout"
    printf 'git worktree add failed (exit %s); see %s\n' "$worktree_rc" "$out/worktree.stderr" >"$executor_stderr"
    : >"$verification_stdout"
    printf 'verification not run because worktree creation failed\n' >"$verification_stderr"
fi

source_after=$(checkout_fingerprint "$repo") || integrity_rc=$?
source_unchanged=false
[[ "$integrity_rc" -eq 0 && "$source_before" == "$source_after" ]] && source_unchanged=true

if [[ "$worktree_rc" -ne 0 ]]; then
    status="setup_failed"
elif [[ "$integrity_rc" -ne 0 ]]; then
    status="integrity_check_failed"
elif [[ "$source_unchanged" != true ]]; then
    status="source_changed"
elif [[ "$executor_rc" -ne 0 ]]; then
    status="executor_failed"
elif [[ "$commit_rc" -ne 0 ]]; then
    status="candidate_commit_failed"
elif [[ "$verification_rc" -ne 0 ]]; then
    status="verification_failed"
elif [[ "$verification_unchanged" != true ]]; then
    status="verification_changed"
elif [[ "$has_changes" != true ]]; then
    status="no_changes"
else
    status="candidate"
fi

candidate=false
[[ "$status" == "candidate" ]] && candidate=true

result=$(jq -nc \
    --arg status "$status" --rawfile task "$task_file" --arg backend "$backend" --arg model "$model" \
    --arg base "$base_commit" --arg commit "$candidate_commit" --arg verify "$verify" \
    --arg branch "$branch" --arg worktree "$worktree" --arg out "$out" --arg patch "$patch_file" \
    --arg executor_stdout_ref "$executor_stdout" --arg executor_stderr_ref "$executor_stderr" \
    --arg verification_stdout_ref "$verification_stdout" --arg verification_stderr_ref "$verification_stderr" \
    --arg parent "$parent_traj" --arg child "$child_traj" --arg child_ref "$child_ref" \
    --argjson candidate "$candidate" --argjson accepted false --argjson changed "$has_changes" \
    --argjson source_unchanged "$source_unchanged" --argjson worktree_exit "$worktree_rc" \
    --argjson executor_exit "$executor_rc" --argjson commit_exit "$commit_rc" \
    --argjson verification_exit "$verification_rc" \
    --argjson verification_unchanged "$verification_unchanged" \
    --argjson integrity_exit "$integrity_rc" --argjson timeout "$timeout_seconds" \
    --arg source_before "$source_before" --arg source_after "$source_after" \
    --arg verification_before "$verification_before" --arg verification_after "$verification_after" \
    --rawfile executor_stdout "$executor_stdout" --rawfile executor_stderr "$executor_stderr" \
    --rawfile verification_stdout "$verification_stdout" --rawfile verification_stderr "$verification_stderr" \
    '{type:"delegation-result", status:$status, candidate:$candidate, accepted:$accepted,
      task:$task, backend:$backend, base_commit:$base,
      candidate_commit:(if $commit == "" then null else $commit end),
      candidate_branch:$branch, has_changes:$changed, worktree:$worktree,
      artifact_dir:$out, patch_ref:$patch, verification_command:$verify,
      worktree_exit_status:$worktree_exit, executor_exit_status:$executor_exit,
      candidate_commit_exit_status:$commit_exit, verification_exit_status:$verification_exit,
      executor_stdout:$executor_stdout, executor_stderr:$executor_stderr,
      verification_stdout:$verification_stdout, verification_stderr:$verification_stderr,
      executor_stdout_ref:$executor_stdout_ref, executor_stderr_ref:$executor_stderr_ref,
      verification_stdout_ref:$verification_stdout_ref, verification_stderr_ref:$verification_stderr_ref,
      source_checkout_unchanged:$source_unchanged,
      verification_checkout_unchanged:$verification_unchanged,
      integrity_check_exit_status:$integrity_exit, timeout_seconds:$timeout,
      source_fingerprint_before:$source_before, source_fingerprint_after:$source_after,
      verification_fingerprint_before:$verification_before, verification_fingerprint_after:$verification_after,
      parent_traj:$parent, child_traj:$child, child_traj_ref:$child_ref}
     + (if $model == "" then {} else {model:$model} end)')
result_step=$(printf '%s' "$result" | TRAJ_DIR="$traj_dir" TRAJ_ID="$child_traj" "$traj_bin" append) \
    || die "could not append delegation result"

summary="$status: backend=$backend base=${base_commit:0:12}"
[[ -n "$candidate_commit" ]] && summary="$summary candidate=${candidate_commit:0:12}"
merge_step=$(TRAJ_DIR="$traj_dir" TRAJ_ID="$parent_traj" "$traj_bin" merge "$child_traj" \
    --field "content=$summary" --field "delegation_status=$status" \
    --field "backend=$backend" --field "base_commit=$base_commit" \
    --field "candidate_commit=$candidate_commit" --field "verification_exit_status=$verification_rc") \
    || die "could not merge delegation result lineage into parent"

printf '%s' "$result" | jq -c --arg result_step "$result_step" --arg merge_step "$merge_step" \
    '. + {result_step:$result_step, parent_merge_step:$merge_step}'

case "$status" in
    candidate) exit 0 ;;
    executor_failed) [[ "$executor_rc" -gt 0 && "$executor_rc" -lt 126 ]] && exit "$executor_rc"; exit 1 ;;
    *) exit 1 ;;
esac
