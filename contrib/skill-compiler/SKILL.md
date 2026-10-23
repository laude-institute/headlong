---
name: skill-compiler
description: Generate and run validation cases for a trusted skill, then inspect a saved report of results and assertion provenance.
metadata:
  shelllm:
    requires:
      bins: ["bash", "python3", "jq", "llm", "shellm", "skills"]
---

# skill-compiler

Use when developing a trusted skill or checking its documented behavior.
Requires Bash, Python 3, jq, llm, shellm, and skills. Model calls use normal llm
configuration and can incur charges. This produces validation reports, not
trained adapters or automatically loaded examples.

```bash
sc="${SKILLS_DIR:-./.skills}/skill-compiler/skill-compiler"
"$sc" compile --skill shellm --num-tests 3 --max-iterations 5
"$sc" show --skill shellm
"$sc" pool --skill shellm
"$sc" clean --skill shellm
```

This skill requires explicit installation; default agents do not receive it.
The executable is not on PATH. See [README.md](README.md) for installation and
source-checkout usage. Use `--teacher-model` only to
override the teacher's configured model. Defaults are up to eight cases and fifteen
iterations per case.

Both compile and pool can execute a skill script with no arguments and with
--help. Probes and tests use disposable state and work directories. Known
messaging/live-store skills and aliases are refused. This is not an OS sandbox:
only run trusted skills, since credentials and filesystem access are not revoked.

Inspect the JSON report's summary.fail as well as the exit status. Runner or
setup failures return nonzero. Assertions require a successful runner and the
named evidence from its actual root run. VERIFIED means the passing literals
are attested in the offered vocabulary, not that the test proves useful behavior.
Review generated cases and include negative examples.

Reports persist under <state-home>/skill-compiler/compiled, outside the skill
installation. See [README.md](README.md) for outcome semantics, report fields,
isolation limits, and optional pool/cache controls.
