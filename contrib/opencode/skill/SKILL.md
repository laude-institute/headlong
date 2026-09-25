---
name: opencode
description: Delegate a bounded coding task to OpenCode and review its retained candidate, patch, verification, and trajectory evidence.
metadata:
  shelllm:
    requires:
      bins: ["bash", "git", "jq", "python3", "perl", "traj"]
      env: ["SHELLM_THINKER_ENV"]
---

Use this capability during the existing `act` action for a bounded coding task
with a meaningful independent verification command. Write the requirements to
a task file and invoke the installed wrapper:

```bash
"$IDENTITY_DIR/extensions/opencode/bin/coding-agent" \
  --repo /absolute/path/to/repository --task-file /absolute/path/to/task.md \
  --verify 'project-specific-check' --out /absolute/path/to/new-artifacts
```

Inspect the status, candidate commit, patch, verification output, and child
trajectory reference. A passing test does not establish that the requirements
are satisfied: review the diff and behavior the test did not cover. Record
rejection and concrete feedback in the trajectory when inadequate. For a
revision, use a fresh output directory and retain earlier candidate/review
references. Leave satisfactory candidates ready for human review with
`accepted:false`. Enablement does not authorize merge, push, deployment, or
acceptance.

The operator may disable this skill between wakes. A remembered absolute path
will then reject new calls; do not bypass that control. Worktrees and model
permissions are not an OS sandbox. See the installed package's README for
runtime configuration and retained artifact cleanup.
