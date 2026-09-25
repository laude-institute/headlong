#!/usr/bin/env python3
"""Reproduce mechanical pass -> semantic rejection -> revised candidate, offline.

This is a scripted fixture experiment, not evidence of autonomous model choice.
Both coding-agent runs, Git worktrees, commits, and trajectory edges are real;
the executor implementations and review policy are deterministic fixtures.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TASK = ("Improve slugify(text) for ASCII text: lowercase letters, preserve digits, "
        "replace each run of non-ASCII-alphanumeric characters (including spaces, "
        "punctuation, tabs, and newlines) with one hyphen, trim leading/trailing "
        "hyphens, and return an empty string for empty or separator-only input.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="new or empty artifacts directory")
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("--out must be new or empty; preserve earlier experiment evidence")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(ROOT.parents[1] / "bin") + os.pathsep + env["PATH"]
    env["SHELLM_THINKER_ENV"] = "local"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["TRAJ_DIR"] = str(out / "trajectories")
    env.pop("TRAJ_ID", None)

    def run(argv, **kw):
        return subprocess.run([str(x) for x in argv], env=env, text=True,
                              capture_output=True, check=True, **kw)

    identity = out / "identity"
    identity.mkdir()
    (identity / "core_identity_prompt.md").touch()
    run([ROOT / "bin/headlong-opencode", "install", "--identity", identity])
    env["PATH"] = str(identity / "extensions/opencode/bin") + os.pathsep + env["PATH"]

    repo = out / "source"
    shutil.copytree(ROOT / "tests/fixtures/collegial-slugify", repo)
    run(["git", "-C", repo, "init", "-q"])
    run(["git", "-C", repo, "add", "."])
    run(["git", "-C", repo, "-c", "user.name=Fixture", "-c",
         "user.email=fixture@example.invalid", "commit", "-qm", "Initial slugify fixture"])
    base = run(["git", "-C", repo, "rev-parse", "HEAD"]).stdout.strip()
    parent = run(["traj", "new", "--slug", "scripted-slugify-review"]).stdout.splitlines()[0]
    env["TRAJ_ID"] = parent
    checker = ROOT / "tests/experiments/verify_slugify.py"

    def append(**entry):
        return run(["traj", "append"], input=json.dumps(entry)).stdout.strip()

    append(type="observation", source="collegial-experiment", invocation="scripted_fixture",
           content="Scripted offline fixture: task selection, executors and review policy are predetermined; no autonomous claim.")
    (out / "task.md").write_text(TASK + "\n\nThe basic check is intentionally weak; review must use the full requirements.\n")

    def delegate(number, target, implementation, task, mode):
        backend = out / ("fake-executor-" + str(number))
        backend.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\n"
                           + "Path('slugify.py').write_text(" + repr(implementation) + ")\n")
        backend.chmod(0o755)
        env["CODING_AGENT_OPENCODE_BIN"] = str(backend)
        run([ROOT / "bin/headlong-opencode", "enable", "--identity", identity])
        verify = shlex.join([sys.executable, str(checker), ".", "--mode", mode])
        completed = run(["coding-agent", "--repo", target, "--task", task,
                         "--verify", verify, "--backend-bin", backend,
                         "--timeout", "10", "--out", out / ("round-" + str(number))])
        result = json.loads(completed.stdout)
        (out / ("result-" + str(number) + ".json")).write_text(json.dumps(result, indent=2) + "\n")
        if result["status"] != "candidate" or result["accepted"]:
            raise RuntimeError("unexpected delegation result")
        return result

    first = delegate(1, repo,
                     'def slugify(text: str) -> str:\n    """Convert text to a URL slug."""\n'
                     '    return text.lower().replace(" ", "-")\n', TASK, "basic")
    review = subprocess.run([sys.executable, str(checker), first["worktree"], "--mode", "full"],
                            env=env, text=True, capture_output=True)
    (out / "review-1.json").write_text(review.stdout)
    feedback = json.loads(review.stdout)
    if review.returncode != 1 or feedback["passed"] or not feedback["failures"]:
        raise RuntimeError("first proposal must fail substantive review")
    rejection = append(type="observation", source="collegial-experiment", verdict="rejected",
                       child_traj=first["child_traj"], candidate_commit=first["candidate_commit"],
                       content="Basic verification passed, but full review found requirement violations.",
                       feedback=feedback)
    second = delegate(2, Path(first["worktree"]),
                      'import re\n\ndef slugify(text: str) -> str:\n'
                      '    """Lowercase ASCII words separated by one hyphen."""\n'
                      '    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")\n',
                      TASK + "\nRevise child " + first["child_traj"]
                      + "; rejection step " + rejection + ". Review feedback: " + json.dumps(feedback), "full")
    final_review = json.loads(run([sys.executable, checker, second["worktree"], "--mode", "full"]).stdout)
    (out / "review-2.json").write_text(json.dumps(final_review, indent=2) + "\n")
    append(type="observation", source="collegial-experiment", verdict="ready_for_human_review",
           child_traj=second["child_traj"], revision_of=first["child_traj"],
           candidate_commit=second["candidate_commit"], accepted=False,
           content="Revised candidate passes full requirements; retained without merging or accepting.")
    dag = run(["traj", "check", "-r"])
    (out / "trajectory-check.txt").write_text(dag.stdout + dag.stderr)
    source_unchanged = (run(["git", "-C", repo, "rev-parse", "HEAD"]).stdout.strip() == base
                        and not run(["git", "-C", repo, "status", "--porcelain"]).stdout.strip())
    if not source_unchanged or second["base_commit"] != first["candidate_commit"]:
        raise RuntimeError("source/revision invariants failed")
    summary = {"invocation": "scripted_fixture", "autonomous": False, "api_calls": 0,
               "parent_traj": parent, "initial_status": first["status"],
               "initial_review": "rejected", "initial_review_failures": len(feedback["failures"]),
               "initial_child": first["child_traj"], "revised_child": second["child_traj"],
               "revised_status": second["status"], "full_review_cases": final_review["cases"],
               "final_verdict": "ready_for_human_review", "accepted": False,
               "source_unchanged": source_unchanged, "revision_based_on_first_candidate": True,
               "candidate_commit": second["candidate_commit"], "worktree": second["worktree"]}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
