# identities/

Identity assets that ship with the repo. Right now that is
[starter-persona.md](starter-persona.md), the template `headlong-init`
uses to draft a new agent's core identity prompt from the install
interview.

[project/](project/) holds the project-mode templates that
`headlong-project init` copies into an identity: charter, project memory,
journal, questions, addenda, `blind` roles and ritual prompts
(design/long_autonomy.md).

Runtime identities (an agent's persona, trajectories, memories, and
activate script) are data, not code. They live in `.identities/`, which
is gitignored.
