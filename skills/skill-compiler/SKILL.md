---
name: skill-compiler
description: Compile a skill specification (SKILL.md) into a validated, cached adapter by synthesizing test cases with a teacher model, executing them, and storing working few-shots as a compiled adjunct.
---

# skill-compiler

## When to use

- You have a SKILL.md that defines a capability but lacks validation examples
- You want to "compile" a skill by generating and testing concrete usage examples
- You're building a new skill and want to verify it works before promoting it
- You want to cache working few-shots so the skill loads faster and more reliably

## What this skill does

This skill implements the "Compile by Training" pattern for Headlong skills:

1. **Read spec** — Parse a SKILL.md file (frontmatter + body) as the specification
2. **Synthesize** — Call a teacher model (via `llm`) to generate validation test cases from the spec
3. **Execute** — Run each test case through `shellm` with the skill available
4. **Validate** — Check that the trajectory produces the expected step type and content
5. **Cache** — Store passing test cases as a compiled markdown adjunct (`.compiled/<skill>.md`)

The compiled cache serves as a "few-shot adapter" — future loads of the skill can include validated examples without re-synthesizing.

## Usage

```bash
# Compile a skill (generates tests, runs them, caches results)
skill-compiler compile --skill shellm --num-tests 3 --max-iterations 5

# List compiled skills
skill-compiler list

# Show the phrase pool a compile hands the teacher
skill-compiler pool --skill shellm

# Show compiled cache for a skill
skill-compiler show --skill shellm

# Clean cache
skill-compiler clean --skill shellm
```

## Options

| Option | Description |
|--------|-------------|
| `--skill NAME` | Skill directory name under `skills/` or `kernel/` |
| `--teacher-model MODEL` | Teacher model for test synthesis (default: `nvidia/nemotron-3-ultra-550b-a55b`) |
| `--num-tests N` | Number of test cases to synthesize (default: 8) |
| `--max-iterations N` | Max shellm iterations per test (default: 15) |

Skills that need credentials, write the live memory store, or message humans are refused at compile time; the skip list lives in the script.

## Output

- `.compiled/<skill>.md` — Human-readable summary with pass/fail for each test and the literal provenance
- `.compiled/<skill>.json` — Self-describing results: a `summary` object (total/passed/verified counts, green-on-invented count, literal provenance) plus `tests`, each entry carrying `literal_labels` and a `verification` status (VERIFIED / GREEN-ON-INVENTED / FAIL)

A pass counts as verified only when every `expect_contains` literal came from the phrase pool the teacher was handed: the tool's own output vocabulary, harvested from its scripts and its documented output, never strings the teacher invented. Literal labels are POOL-EXACT (a whole pool entry), POOL-FRAGMENT (a constant fragment of one), INVENTED (nowhere in the pool, unverified).

## Test case format

Each synthesized test case is a JSON object:

```json
{
  "name": "short-identifier",
  "prompt": "exact prompt to send to shellm",
  "expect": "observation|thought|error",
  "expect_contains": ["substring1", "substring2"]
}
```

## Requirements

- `llm` CLI (for teacher model calls)
- `shellm` (for test execution)
- `jq` (for JSON processing)
- `SKILLS_DIR` and `SKILLS_KERNEL_DIR` environment variables set (the script defaults to its own parent directory and the kernel dir beside it)

## Future: Trained adapter compilation

This skill currently implements the "fast compiler" (prompt scaffolds + validation). The CbT paper suggests a second phase: training LoRA adapters on the validated examples for fuzzy-spec breakthrough. That would be a separate `skill-compiler-train` skill or mode.
