#!/usr/bin/env bash
# tests/test_thinker_env_fallback.sh — a thinker finds the API key where the
# installer actually wrote it.
#
# tools/headlong-init writes the provider key and SHELLM_MODEL to
# $HEADLONG_HOME/.env and nowhere else. The thinker step scripts resolve those
# BEFORE calling llm/shellm (which load .env too late to influence the -m
# flag), so _require_env has to read that file. It cannot lean on llm to do it
# instead: both launchers export SHELLM_HOME as <identity>/.shellm
# (bin/thinkers, web control.py), and llm resolves the state home through
# SHELLM_HOME, so under a thinker it reads the identity directory rather than
# the framework state home.
#
# The legacy ~/.shellm case is here because a pre-rename install keeps its
# state there, and the "already set wins" case because the dispatcher's own
# environment (deploy/thinkers-service.sh, the web _ENV_WRAPPER) must always
# beat a file.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# An ambient SHELLM_TRAJ_DIR (set by any run inside shellm) outranks the
# TRAJ_DIR each arm sets below, because bin/shellm resolves SHELLM_TRAJ_DIR
# first; without this, a run inside a live wake writes its nested shellm run
# into the caller's real log.
unset SHELLM_TRAJ_DIR

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# probe <name> <expected-key-value> <setup-fn> -- runs _require_env in a fresh
# HOME laid out by <setup-fn>. The subshell clears the env vars under test so
# an ambient key or HEADLONG_HOME on the developer's machine cannot make a case
# pass or fail for the wrong reason (and cannot print a real key on failure).
probe() {
    local name="$1" want="$2" setup="$3"
    local out
    out=$(
        H=$(mktemp -d)
        trap 'rm -rf "$H"' EXIT
        export HOME="$H"
        unset OPENROUTER_API_KEY HEADLONG_HOME SHELLM_HOME
        mkdir -p "$H/id/memories" "$H/id/skills" "$H/id/kernel" "$H/id/trajectories" "$H/wd"
        printf 'name=probe\n' > "$H/id/info.txt"
        "$setup" "$H"
        export IDENTITY_DIR="$H/id" TRAJ_DIR="$H/id/trajectories" TRAJ_ID=t1 MEM_DIR="$H/id/memories"
        cd "$H/wd" || exit 1
        # shellcheck disable=SC1090  # the library under test
        source "$REPO/thinkers/_lib/common.sh"
        _require_env >/dev/null 2>&1
        printf '%s' "${OPENROUTER_API_KEY:-<unset>}"
    )
    if [[ "$out" == "$want" ]]; then
        ok "$name"
    else
        bad "$name" "expected $want, got $out"
    fi
}

# Each writes the key into one of the places the loader consults.
setup_headlong() { mkdir -p "$1/.headlong"; printf 'OPENROUTER_API_KEY=from-headlong\n' > "$1/.headlong/.env"; }
setup_legacy()   { mkdir -p "$1/.shellm";   printf 'OPENROUTER_API_KEY=from-legacy\n'   > "$1/.shellm/.env"; }
setup_both()     { setup_headlong "$1"; setup_legacy "$1"; }
# Also write the state-home and legacy files, so "identity wins over both"
# proves precedence rather than merely that the identity file is read.
setup_identity() { setup_both "$1"; printf 'OPENROUTER_API_KEY=from-identity\n' > "$1/id/.env"; }
setup_none()     { :; }

probe "state home .env is read"                 from-headlong setup_headlong
probe "legacy ~/.shellm/.env still read"        from-legacy   setup_legacy
probe "state home wins over the legacy path"    from-headlong setup_both
probe "identity .env still wins over both"      from-identity setup_identity
probe "no env file leaves the key unset"        '<unset>'     setup_none

# HEADLONG_HOME points the lookup somewhere else entirely.
out=$(
    H=$(mktemp -d); trap 'rm -rf "$H"' EXIT; export HOME="$H"
    unset OPENROUTER_API_KEY SHELLM_HOME
    mkdir -p "$H/id" "$H/elsewhere" "$H/.headlong" "$H/wd"
    printf 'name=probe\n' > "$H/id/info.txt"
    printf 'OPENROUTER_API_KEY=from-default\n' > "$H/.headlong/.env"
    printf 'OPENROUTER_API_KEY=from-override\n' > "$H/elsewhere/.env"
    export HEADLONG_HOME="$H/elsewhere"
    export IDENTITY_DIR="$H/id" TRAJ_DIR="$H/id" TRAJ_ID=t1 MEM_DIR="$H/id"
    cd "$H/wd" || exit 1
    # shellcheck disable=SC1090  # the library under test
    source "$REPO/thinkers/_lib/common.sh"
    _require_env >/dev/null 2>&1
    printf '%s' "${OPENROUTER_API_KEY:-<unset>}"
)
[[ "$out" == from-override ]] && ok "HEADLONG_HOME overrides the default state home" \
    || bad "HEADLONG_HOME overrides the default state home" "got $out"

# The dispatcher's own environment must always beat a file.
out=$(
    H=$(mktemp -d); trap 'rm -rf "$H"' EXIT; export HOME="$H"
    unset HEADLONG_HOME SHELLM_HOME
    mkdir -p "$H/id" "$H/.headlong" "$H/wd"
    printf 'name=probe\n' > "$H/id/info.txt"
    printf 'OPENROUTER_API_KEY=from-file\n' > "$H/.headlong/.env"
    export OPENROUTER_API_KEY=from-environment
    export IDENTITY_DIR="$H/id" TRAJ_DIR="$H/id" TRAJ_ID=t1 MEM_DIR="$H/id"
    cd "$H/wd" || exit 1
    # shellcheck disable=SC1090  # the library under test
    source "$REPO/thinkers/_lib/common.sh"
    _require_env >/dev/null 2>&1
    printf '%s' "$OPENROUTER_API_KEY"
)
[[ "$out" == from-environment ]] && ok "an already-set value wins over the file" \
    || bad "an already-set value wins over the file" "got $out"

# The key has to reach the nested shellm as a bare --var NAME, or the model
# still runs without it inside Docker.
out=$(
    H=$(mktemp -d); trap 'rm -rf "$H"' EXIT; export HOME="$H"
    unset OPENROUTER_API_KEY HEADLONG_HOME SHELLM_HOME
    mkdir -p "$H/id/memories" "$H/id/skills" "$H/id/kernel" "$H/id/trajectories" "$H/.headlong" "$H/wd"
    printf 'name=probe\n' > "$H/id/info.txt"
    printf 'OPENROUTER_API_KEY=from-headlong\n' > "$H/.headlong/.env"
    export IDENTITY_DIR="$H/id" TRAJ_DIR="$H/id/trajectories" TRAJ_ID=t1 MEM_DIR="$H/id/memories"
    cd "$H/wd" || exit 1
    # shellcheck disable=SC1090  # the library under test
    source "$REPO/thinkers/_lib/common.sh"
    _require_env >/dev/null 2>&1
    _build_shellm_flags "$IDENTITY_DIR" 2>/dev/null | tr '\n' ' '
)
case "$out" in
    *"--var OPENROUTER_API_KEY "*) ok "the key is forwarded to the nested shellm" ;;
    *) bad "the key is forwarded to the nested shellm" "no bare --var for it" ;;
esac

# A shell-local provider key must be exported before flags are assembled in a
# process substitution. Exercise a real nested shellm: without the parent
# export, its bare --var parser fails before generated code can see the key.
out=$(
    H=$(mktemp -d); trap 'rm -rf "$H"' EXIT; export HOME="$H"
    unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY \
          OPENCODE_API_KEY LLM_API_KEY HEADLONG_HOME SHELLM_HOME
    mkdir -p "$H/id/memories" "$H/id/skills" "$H/id/kernel" "$H/id/trajectories" "$H/wd" "$H/bin"
    printf 'name=probe\n' > "$H/id/info.txt"
    cat > "$H/bin/llm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '```bash' 'if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then FINAL=provider-key-present; else FINAL=provider-key-missing; fi' '```'
EOF
    chmod +x "$H/bin/llm"
    export PATH="$H/bin:$REPO/bin:$REPO/tools:$PATH"
    export IDENTITY_DIR="$H/id" TRAJ_DIR="$H/id/trajectories" TRAJ_ID=t1 MEM_DIR="$H/id/memories"
    export SHELLM_MODEL=test-model SHELLM_THINKER_ENV=local
    OPENROUTER_API_KEY=synthetic-provider-key
    cd "$H/wd" || exit 1
    # shellcheck disable=SC1090  # the library under test
    source "$REPO/thinkers/_lib/common.sh"
    _require_env >/dev/null 2>&1
    _export_provider_keys
    flags=()
    while IFS= read -r flag; do
        [[ -n "$flag" ]] && flags+=("$flag")
    done < <(_build_shellm_flags "$IDENTITY_DIR" "$H/wd")
    nested_out=$("$REPO/bin/shellm" "${flags[@]}" --max-iterations 1 key-probe 2>/dev/null)
    printf '%s\n' "$nested_out"
    row=$(grep -rh '"type":"shellm-run"' "$H/id/trajectories" 2>/dev/null | tail -1)
    if [[ "$row" == *"--var OPENROUTER_API_KEY "* && "$row" != *"synthetic-provider-key"* ]]; then
        printf 'provider-key-command-safe\n'
    fi
)
if [[ "$out" == *provider-key-present* && "$out" == *provider-key-command-safe* ]]; then
    ok "an unexported provider key reaches an actual nested shellm"
else
    bad "an unexported provider key reaches an actual nested shellm" "got $out"
fi

# Endpoints are inherited rather than repeated as --var, because shellm owns
# their Docker rewrite. Skill-declared values still use bare --var NAME, and an
# existing-but-unexported skill value must be exported in the parent before
# flag assembly runs in process substitution.
out=$(
    H=$(mktemp -d); trap 'rm -rf "$H"' EXIT; export HOME="$H"
    unset HEADLONG_HOME SHELLM_HOME
    mkdir -p "$H/id/memories" "$H/id/skills/probe" "$H/id/kernel" "$H/id/trajectories" "$H/wd"
    printf 'name=probe\n' > "$H/id/info.txt"
    cat > "$H/id/skills/probe/SKILL.md" <<'EOF'
---
name: probe
description: Test fixture.
metadata:
  shelllm:
    requires:
      env: ["PROBE_SERVICE_CONFIG", "LLM_API_URL", "SHELLM_API_URL"]
---
EOF
    export IDENTITY_DIR="$H/id" TRAJ_DIR="$H/id/trajectories" TRAJ_ID=t1 MEM_DIR="$H/id/memories"
    export LLM_API_URL="https://example.invalid/v1/responses"
    unset SHELLM_API_URL
    # Intentionally unexported: _export_skill_vars must promote it for --var NAME.
    # shellcheck disable=SC2034
    PROBE_SERVICE_CONFIG="private-config-canary"
    cd "$H/wd" || exit 1
    # shellcheck disable=SC1090  # the library under test
    source "$REPO/thinkers/_lib/common.sh"
    _require_env >/dev/null 2>&1
    _export_skill_vars "$IDENTITY_DIR"
    _build_shellm_flags "$IDENTITY_DIR" 2>/dev/null | tr '\n' ' '
    if bash -c '[[ -n "${LLM_API_URL:-}" && -n "${PROBE_SERVICE_CONFIG:-}" ]]'; then
        printf 'parent-export-ok '
    fi
)
case "$out" in
    *"example.invalid"*|*"private-config-canary"*) bad "private config values stay out of thinker shellm flags" ;;
    *)
        if [[ "$out" != *"--var SHELLM_API_URL "* \
           && "$out" != *"--var LLM_API_URL "* \
           && "$out" == *"--var PROBE_SERVICE_CONFIG "* \
           && "$out" == *"parent-export-ok "* ]]; then
            ok "endpoint is inherited and an unexported skill var is parent-exported"
        else
            bad "endpoint is inherited and an unexported skill var is parent-exported" "unexpected flags or missing parent export"
        fi
        ;;
esac

# Under set -e (how every thinker step runs), a skill that declares a var the
# environment does not set must not end _export_skill_vars on a false test —
# that killed every Audel wake after the 2026-09-05 deploy.
out=$(
    H=$(mktemp -d)
    trap 'rm -rf "$H"' EXIT
    export HOME="$H"
    unset HEADLONG_HOME SHELLM_HOME ZZ_UNSET_SKILL_VAR
    mkdir -p "$H/id/skills/probe" "$H/id/kernel"
    cat > "$H/id/skills/probe/SKILL.md" <<'EOF'
---
name: probe
description: Test fixture.
metadata:
  shelllm:
    requires:
      env: ["ZZ_UNSET_SKILL_VAR"]
---
EOF
    set -euo pipefail
    # shellcheck disable=SC1090  # the library under test
    source "$REPO/thinkers/_lib/common.sh"
    _export_skill_vars "$H/id"
    _export_provider_keys
    printf 'survived'
)
if [[ "$out" == "survived" ]]; then
    ok "unset declared skill var does not kill a set -e caller"
else
    bad "unset declared skill var does not kill a set -e caller" "caller exited early"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
