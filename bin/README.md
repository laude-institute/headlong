# bin/

The core harness. Every executable here is pure Bash and runs inside the
mind: `shellm` (the RLM engine), `llm`, `traj`, `context`, `thinkers`,
and the smaller tools around them. The table in the root
[README](../README.md) says what each one does, and
[docs/shellm.md](../docs/shellm.md) is the engine reference.

Code in `bin/` and `thinkers/` counts against the core line budget CI
enforces (`cloc bin/ thinkers/` against `LOC_LIMIT` in
`.github/workflows/ci.yml`), so keep additions small. Tooling that runs
around the mind rather than inside it belongs in [tools/](../tools/).
