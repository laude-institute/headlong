---
name: custos-decisions
description: Ask Tycho's local Snap model for bounded choices, scores, or evidence assessments using decide. Useful for classification, relevance ranking and explicit rubrics.
---

# Local typed decisions

`decide REQUEST.json` (or `decide -` for JSON stdin) calls Snap1-2B Q8 on Tycho
through the operator-owned local broker. `decide --status` describes configuration;
it is not an inference health check. This helper is separate from your generative
Johan → OpenRouter route. Its decision fallback is TypeSafe Jev (`jev-latest`),
through the existing operator broker. Hal authorized this fallback on October 9.
If Tycho is unavailable, the same bounded evidence can leave the homelab for
TypeSafe. Do not separately call the old `custos-jev` command.

Use it for bounded semantic judgments over evidence you already have. It cannot
browse, write explanations, discover facts, authorize actions, or prove an answer.
Use ordinary code for arithmetic, deadlines, permission checks and receipt status.

```json
{
  "state": {"abstract": "A tested inference method; source code is unavailable."},
  "questions": {
    "kind": {
      "type": "choice",
      "instructions": "Classify the described contribution using only the abstract.",
      "criteria": {
        "research": "An evaluated technical method",
        "product": "A product announcement",
        "insufficient": "The description does not establish either"
      }
    }
  }
}
```

Results identify the actual provider and model: `tycho` / `snap:2b` with its pinned
artifact hash, or `typesafe` / `jev-latest` with `fallback: true`. Jev has no local
artifact hash and its broker does not report provider truncation. Choice has a label and distribution. Score has a
fractional position on an ordered rubric and its distribution. Noul is a number
between zero and one for the supplied yes/no claim. These scores are not calibrated
probabilities of correctness. Include an insufficient/no-match option where useful.

Limits: 24 KiB JSON, 1–8 independent questions, 2–26 choice labels or 2–10 score
levels, and the model's 8K context. Labels use letters/digits/underscore/dot/hyphen.
Errors, including oversized contexts, return JSON and a nonzero status. There is no
automatic retry after both providers fail. Invalid input is not sent to the fallback.
On uncertainty or unavailability, reason from evidence yourself; do not repeatedly
poll or change providers. Never include credentials. Other restrictions on source
access and actions still apply. Automatic hooks have a 2.25-second total inference
deadline; an explicit tool call permits 29 seconds for the slower fallback.

Run synchronously. Existing restrictions on generative subruns remain unchanged.
Independent questions can share state; they cannot see one another's answers.

Headlong also runs three automatic **shadow** checks: context/skill relevance,
semantic progress, and grounding of responder replies or shellm final reports.
Their assessments go to private `run/logs/decisions/assessments.jsonl`, outside your
reasoning context. They do not filter skills, compact memory, stop work, rewrite
responses, or block delivery. Observation results are evaluation data, not new policy.
