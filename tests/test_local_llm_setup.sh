#!/usr/bin/env bash
# tests/test_local_llm_setup.sh — headlong-init's local (OpenAI-compatible)
# model-server setup path.
#
# Usage: tests/test_local_llm_setup.sh
#
# Why: the openai-compatible provider existed in bin/llm, but the installer
# only knew how to ask for a cloud API key — a local Ollama/LM Studio setup
# had to be configured by hand after install (issue #65). This pins the
# installer flow:
#
#   - HEADLONG_PROVIDER=local with HEADLONG_LOCAL_URL + HEADLONG_LOCAL_MODEL
#     completes with NO cloud key of any kind set, and persists
#     LLM_PROVIDER=openai-compatible, SHELLM_API_URL and SHELLM_MODEL
#   - the endpoint is verified with GET <base>/v1/models before anything is
#     written (a bad URL dies with a clear message, writes nothing)
#   - a base URL is normalized to the chat-completions URL bin/llm wants;
#     a full .../v1/chat/completions URL is accepted and kept as-is
#   - HEADLONG_LOCAL_MODEL wins over the server's list order (the operator's
#     explicit pick, not "first model in the list")
#   - the final proof is a real chat completion through bin/llm, so the
#     probe covers the exact chain a thinker will use
#   - HEADLONG_PROVIDER=cloud ignores local env vars entirely (the old path)
#   - a re-run keeps the local config without re-asking (idempotence)
#
# curl, docker, jq and llm are stubs; no network and no daemon are touched.
# Fixture keys below carry only a prefix shape and are deliberately not valid
# provider keys.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check()     { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else bad "$l"; fi; }
check_not() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$l"; else ok "$l"; fi; }

# --- stubs -------------------------------------------------------------------
STUB="$WORK/stub"; mkdir -p "$STUB"

# curl: answer GET <base>/models from $CURL_MODELS_FILE (JSON body); append
# every /models hit to $CURL_MODELS_HITS (append, not last-write: init's
# dash-readiness poll curls too, and those must not erase the probe record).
# Every other request "fails" (empty reply), which is what a dead endpoint
# looks like to the caller. CURL_MODELS_UP=0 makes even /models unreachable
# (connection refused, rc 7) — a server that is simply down.
cat > "$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
url=""
prev=""
out_file=""
for a in "$@"; do
    [[ "$prev" != -* && "$a" == http* ]] && url="$a"
    [[ "$prev" == "-o" ]] && out_file="$a"
    if [[ "$prev" == "-K" ]]; then
        cat "$a" > "$CURL_AUTH_FILE"
        { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } > "$CURL_AUTH_MODE"
    fi
    prev="$a"
done
printf '%s\n' "$@" >> "$CURL_ARGS"
case "$url" in
    */models)
        if [[ "${CURL_MODELS_UP:-1}" != "1" ]]; then
            printf 'curl: (7) Failed to connect\n' >&2
            exit 7
        fi
        printf '%s\n' "$url" >> "$CURL_MODELS_HITS"
        if [[ -n "$out_file" ]]; then
            cat "$CURL_MODELS_FILE" > "$out_file" 2>/dev/null || printf '{"data":[]}' > "$out_file"
        else
            cat "$CURL_MODELS_FILE" 2>/dev/null || printf '{"data":[]}'
        fi
        printf '%s' "${CURL_MODELS_STATUS:-200}"
        exit 0
        ;;
esac
exit 7
STUBEOF

# docker: daemon up, nothing else (no image pull).
printf '#!/usr/bin/env bash\ncase "${1:-}" in info) exit 0 ;; *) exit 0 ;; esac\n' > "$STUB/docker"

# llm: an init that gets this far proves the chain. Optionally record whether
# local routing variables were present in the environment. A cloud switch
# must pass them as explicitly empty so the real llm cannot reload them from
# the saved state .env.
cat > "$STUB/llm" <<'STUBEOF'
#!/usr/bin/env bash
if [[ -n "${LLM_ENV_CAPTURE:-}" ]]; then
    printf 'LLM_PROVIDER=%s:%s\n' "${LLM_PROVIDER+x}" "${LLM_PROVIDER-}" > "$LLM_ENV_CAPTURE"
    printf 'SHELLM_API_URL=%s:%s\n' "${SHELLM_API_URL+x}" "${SHELLM_API_URL-}" >> "$LLM_ENV_CAPTURE"
    printf 'LLM_API_URL=%s:%s\n' "${LLM_API_URL+x}" "${LLM_API_URL-}" >> "$LLM_ENV_CAPTURE"
    printf 'LLM_API_KEY=%s:%s\n' "${LLM_API_KEY+x}" "${LLM_API_KEY-}" >> "$LLM_ENV_CAPTURE"
    printf 'SHELLM_MODEL=%s\n' "${SHELLM_MODEL-}" >> "$LLM_ENV_CAPTURE"
fi
exit "${LLM_STUB_RC:-0}"
STUBEOF

chmod +x "$STUB/curl" "$STUB/docker" "$STUB/llm"

# A minimal fake checkout: headlong-init only checks that bin/shellm exists
# under HEADLONG_APP_DIR, but the no-tty path still creates an identity (the
# cloud tests drive it all the way there), so the tools it calls must exist.
APP="$WORK/app"; mkdir -p "$APP/bin" "$APP/tools"
: > "$APP/bin/shellm"
cp "$REPO/tools/headlong-init" "$APP/tools/headlong-init"

# identity: create the directory structure init writes into (memories, chat),
# without the real tool's behavior.
cat > "$APP/tools/identity" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "new" ]] || exit 0
name="${2:-ada}"; shift 2 || true
root="${IDENTITY_DIR:?IDENTITY_DIR not set}"
mkdir -p "$root/$name/memories" "$root/$name/chat"
# init sources activate and requires IDENTITY_NAME from it (thinkers start).
cat > "$root/$name/activate" <<'ACTEOF'
export IDENTITY_NAME=ada
ACTEOF
STUBEOF
chmod +x "$APP/tools/identity"

# thinkers / headlong-web: dash startup is skipped in these runs
# (HEADLONG_NO_DASH=1: the dash is not this suite's subject, and a live
# dash makes init open a browser and poll readiness). The stubs exist so
# a stray call fails loudly in $WORK/out instead of 'command not found'.
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/tools/thinkers"
cat > "$APP/tools/headlong-web" <<'STUBEOF'
#!/usr/bin/env bash
echo "headlong-web serving http://127.0.0.1:8099"
sleep 9999
STUBEOF
chmod +x "$APP/tools/thinkers" "$APP/tools/headlong-web"

# The persona phase reads the checkout's starter template (and the dash phase
# checks web/src/headlong_web/static/index.html).
mkdir -p "$APP/identities" "$APP/web/src/headlong_web/static"
printf 'name: {{identity_name}}\nvibe: {{vibe}}\nfocus: {{focus}}\n' \
    > "$APP/identities/starter-persona.md"
printf '<html></html>' > "$APP/web/src/headlong_web/static/index.html"

MODELS_FILE="$WORK/models.json"
CURL_MODELS_HITS="$WORK/models_hits"
CURL_ARGS="$WORK/curl_args"
CURL_AUTH_FILE="$WORK/curl_auth"
CURL_AUTH_MODE="$WORK/curl_auth_mode"
LLM_ENV_CAPTURE="$WORK/llm_env"
: > "$CURL_MODELS_HITS"
: > "$CURL_ARGS"
: > "$CURL_AUTH_FILE"
: > "$CURL_AUTH_MODE"

# run_init <home> [VAR=VAL ...] — headlong-init with no tty, no inherited
# keys or local config, stubs first on PATH. Output to $WORK/out; the exit
# code lands in $RC (captured immediately — a following check() call would
# otherwise overwrite $?).
RC=0
run_init() {
    local home="$1"; shift
    mkdir -p "$home"
    env -i \
        HOME="$home" HEADLONG_HOME="$home/.headlong" HEADLONG_APP_DIR="$APP" \
        HEADLONG_NO_TTY=1 HEADLONG_UNSANDBOXED="${HEADLONG_UNSANDBOXED:-1}" \
        HEADLONG_NO_DASH=1 PATH="$STUB:$PATH" \
        CURL_MODELS_FILE="$MODELS_FILE" CURL_MODELS_HITS="$CURL_MODELS_HITS" \
        CURL_MODELS_UP="${CURL_MODELS_UP:-1}" CURL_MODELS_STATUS="${CURL_MODELS_STATUS:-200}" \
        CURL_ARGS="$CURL_ARGS" CURL_AUTH_FILE="$CURL_AUTH_FILE" CURL_AUTH_MODE="$CURL_AUTH_MODE" \
        LLM_STUB_RC="${LLM_STUB_RC:-0}" LLM_ENV_CAPTURE="${LLM_ENV_CAPTURE_ACTIVE:+$LLM_ENV_CAPTURE}" "$@" \
        bash "$APP/tools/headlong-init" </dev/null > "$WORK/out" 2>&1
    RC=$?
}

# ---------------------------------------------------------------------------
# local + URL + model: the full no-tty happy path
# ---------------------------------------------------------------------------
printf '{"data":[{"id":"qwen3:8b"},{"id":"gemma3:12b"},{"id":"llama3.2"}]}' > "$MODELS_FILE"
run_init "$WORK/h1" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "local path: exits 0"                                  test "$RC" -eq 0
check "local path: persists LLM_PROVIDER=openai-compatible"  grep -qx "LLM_PROVIDER='openai-compatible'" "$WORK/h1/.headlong/.env"
check "local path: persists the chat-completions URL"        grep -qx "SHELLM_API_URL='http://127.0.0.1:11434/v1/chat/completions'" "$WORK/h1/.headlong/.env"
check "local path: persists the requested model"             grep -qx "SHELLM_MODEL='qwen3:8b'" "$WORK/h1/.headlong/.env"
check_not "local path: no key written"                       grep -q '^LLM_API_KEY=' "$WORK/h1/.headlong/.env"
check "local path: models probe hit /v1/models"              grep -q '127.0.0.1:11434/v1/models' "$CURL_MODELS_HITS"

# .env values are single-quoted, so a server-supplied model id carrying
# shell metacharacters can neither execute when the file is sourced nor
# even be stored: the id is rejected before anything is written.
rm -f "$WORK/pwned"
printf '{"data":[{"id":"qwen3$(touch %s/pwned)"}]}' "$WORK" > "$MODELS_FILE"
run_init "$WORK/hrce" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1
check "malicious model id: init refuses"                      test "$RC" -ne 0
check_not "malicious model id: nothing executed on the host"  test -e "$WORK/pwned"
check_not "malicious model id: not persisted"                 grep -q 'pwned' "$WORK/hrce/.headlong/.env"

# A whitespace-bearing id is likewise refused (it would break sourcing).
printf '{"data":[{"id":"qwen3 8b"}]}' > "$MODELS_FILE"
run_init "$WORK/hrce2" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1
check "space in model id: init refuses"                       test "$RC" -ne 0

printf '{"data":[{"id":"qwen3:8b"},{"id":"gemma3:12b"},{"id":"llama3.2"}]}' > "$MODELS_FILE"

# A stray cloud key in the environment must not leak into the local .env.
run_init "$WORK/h1b" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    SHELLM_MODEL=openai/gpt-oss-120b \
    ANTHROPIC_API_KEY=«redacted:sk-ant-…»
check_not "local path: a cloud key in the env stays out of the local .env" \
    grep -q 'ANTHROPIC_API_KEY' "$WORK/h1b/.headlong/.env"
check "local path: a cloud model does not override the server list" \
    grep -qx "SHELLM_MODEL='qwen3:8b'" "$WORK/h1b/.headlong/.env"

# ---------------------------------------------------------------------------
# a dead endpoint: verify first, write nothing
# ---------------------------------------------------------------------------
printf '{"data":[{"id":"qwen3:8b"}]}' > "$MODELS_FILE"
CURL_MODELS_UP=0 run_init "$WORK/h2" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:9999/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "dead endpoint: exits nonzero"                         test "$RC" -ne 0
check "dead endpoint: says it could not reach the server"    grep -qi 'could not reach\|could not list' "$WORK/out"
# The sandbox gate writes its own lines before the provider step; what matters
# is that no local-model config was persisted for a server that is not there.
check_not "dead endpoint: no local config persisted"         grep -q '^LLM_PROVIDER=' "$WORK/h2/.headlong/.env"

# Credentials embedded in an endpoint URL are needed by the HTTP client but
# must not be repeated in terminal or CI output, on success or failure.
CURL_MODELS_UP=0 run_init "$WORK/h2b" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://local-user:local-pass@127.0.0.1:9999/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "credential URL: failure still identifies the host"    grep -q '127.0.0.1:9999' "$WORK/out"
check_not "credential URL: userinfo is redacted from output"  grep -q 'local-user\|local-pass' "$WORK/out"
run_init "$WORK/h2c" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://local-user:local-pass@127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "credential URL: successful setup exits 0"             test "$RC" -eq 0
check_not "credential URL: success output is also redacted"   grep -q 'local-user\|local-pass' "$WORK/out"

# ---------------------------------------------------------------------------
# URL normalization: a full chat-completions URL is accepted as given
# ---------------------------------------------------------------------------
run_init "$WORK/h3" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:8080/v1/chat/completions \
    HEADLONG_LOCAL_MODEL=gemma3:12b
check "full URL accepted: exits 0"                           test "$RC" -eq 0
check "full URL accepted: kept as the chat URL"              grep -qx "SHELLM_API_URL='http://127.0.0.1:8080/v1/chat/completions'" "$WORK/h3/.headlong/.env"
check "full URL accepted: model probe still hit /v1/models"  grep -q '127.0.0.1:8080/v1/models' "$CURL_MODELS_HITS"

# A trailing slash on the base URL must not double up.
run_init "$WORK/h3b" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1/ \
    HEADLONG_LOCAL_MODEL=llama3.2
check "trailing slash: exits 0"                              test "$RC" -eq 0
check "trailing slash: normalized chat URL"                  grep -qx "SHELLM_API_URL='http://127.0.0.1:11434/v1/chat/completions'" "$WORK/h3b/.headlong/.env"

# ---------------------------------------------------------------------------
# a key for a locked-down endpoint is persisted
# ---------------------------------------------------------------------------
printf '{"data":[{"id":"qwen3:8b"}]}' > "$MODELS_FILE"
run_init "$WORK/h4" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:1234/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b \
    HEADLONG_LOCAL_API_KEY=«redacted:lm-studio-…»
check "local key: exits 0"                                   test "$RC" -eq 0
check "local key: persisted"                                 grep -qx "LLM_API_KEY='«redacted:lm-studio-…»'" "$WORK/h4/.headlong/.env"
check_not "local key: stays off curl argv"                   grep -q 'lm-studio' "$CURL_ARGS"
check "local key: auth file is private"                      grep -qx '600' "$CURL_AUTH_MODE"

# A stale LLM_API_KEY inherited from a prior/keyed .env must NOT be sent as
# a Bearer token to a newly selected server, nor persisted for it: a key
# belongs to the endpoint it was set for. Selecting a fresh HEADLONG_LOCAL_URL
# means no key unless one is given for that server.
: > "$CURL_AUTH_FILE"
run_init "$WORK/h4e" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:5678/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b \
    LLM_API_KEY=stale-cloud-secret
check "stale key: exits 0"                                   test "$RC" -eq 0
check_not "stale key: no Bearer sent to the new server"      test -s "$CURL_AUTH_FILE"
check_not "stale key: not persisted for the new endpoint"    grep -q '^LLM_API_KEY=' "$WORK/h4e/.headlong/.env"

# A reachable server may support chat without exposing its model catalog.
# An explicit model is enough in that case.
CURL_MODELS_STATUS=404 run_init "$WORK/h4b" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:1234/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "models 404: explicit model still works"               test "$RC" -eq 0
check "models 404: requested model is persisted"             grep -qx "SHELLM_MODEL='qwen3:8b'" "$WORK/h4b/.headlong/.env"

# An OpenAI-compatible server with NO models pulled yet ({"data":[]}) is a
# healthy server, not a protocol error: with an explicit model it succeeds,
# and without one it dies telling the operator to provide a model — never
# the misleading "is it an OpenAI-compatible server?" message.
printf '{"data":[]}' > "$MODELS_FILE"
run_init "$WORK/h4c" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:1234/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "empty model list + explicit model: exits 0"           test "$RC" -eq 0
run_init "$WORK/h4d" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:1234/v1
check "empty model list, no model: exits nonzero"            test "$RC" -ne 0
check_not "empty model list: not blamed as incompatible"     grep -qi 'OpenAI-compatible server?' "$WORK/out"
printf '{"data":[{"id":"qwen3:8b"}]}' > "$MODELS_FILE"

# ---------------------------------------------------------------------------
# no model pinned, server exposes several: first in the list is used
# ---------------------------------------------------------------------------
run_init "$WORK/h5" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1
check "no model pin: exits 0"                                test "$RC" -eq 0
check "no model pin: first listed model chosen"              grep -qx "SHELLM_MODEL='qwen3:8b'" "$WORK/h5/.headlong/.env"

# ---------------------------------------------------------------------------
# the final check is a real completion: a failing chain fails the setup
# ---------------------------------------------------------------------------
LLM_STUB_RC=1 run_init "$WORK/h6" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "failing completion: exits nonzero"                    test "$RC" -ne 0
check "failing completion: says chat did not answer"         grep -qi 'did not answer\|chat completion' "$WORK/out"
# A failed chat check must persist nothing: a broken local provider left in
# .env would shadow a working cloud key on every later run.
check_not "failing completion: no local provider persisted"  grep -q '^LLM_PROVIDER=' "$WORK/h6/.headlong/.env"
check_not "failing completion: no local URL persisted"       grep -q '^SHELLM_API_URL=' "$WORK/h6/.headlong/.env"

# ---------------------------------------------------------------------------
# cloud wins explicitly: local env vars are ignored. The stub llm fails, so a
# nonzero exit proves the cloud key path was taken (and its failure mode is
# the key check, not the local flow).
# ---------------------------------------------------------------------------
LLM_STUB_RC=1 run_init "$WORK/h7" \
    HEADLONG_PROVIDER=cloud \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b \
    OPENAI_API_KEY=«redacted:sk-…»
check "cloud explicit: exits nonzero (stub llm fails, as in the key tests)" test "$RC" -ne 0
check_not "cloud explicit: no local config written"          grep -q 'SHELLM_API_URL' "$WORK/h7/.headlong/.env"

# An explicit cloud choice on a configured local install removes every local
# routing value and picks the cloud provider's default model.
run_init "$WORK/h7b" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b \
    HEADLONG_LOCAL_API_KEY=local-secret
LLM_ENV_CAPTURE_ACTIVE=1 run_init "$WORK/h7b" \
    HEADLONG_PROVIDER=cloud \
    OPENAI_API_KEY=«redacted:sk-…»
check "local to cloud: exits 0"                              test "$RC" -eq 0
check_not "local to cloud: removes the local provider"       grep -q '^LLM_PROVIDER=' "$WORK/h7b/.headlong/.env"
check_not "local to cloud: removes the local URL"            grep -q '^SHELLM_API_URL=' "$WORK/h7b/.headlong/.env"
check_not "local to cloud: removes the local key"            grep -q '^LLM_API_KEY=' "$WORK/h7b/.headlong/.env"
check "local to cloud: selects the OpenAI model"             grep -qx "SHELLM_MODEL='gpt-5.5'" "$WORK/h7b/.headlong/.env"
check "local to cloud: masks saved provider during validation" \
    grep -qx 'LLM_PROVIDER=x:' "$LLM_ENV_CAPTURE"
check "local to cloud: masks saved URL during validation" \
    grep -qx 'SHELLM_API_URL=x:' "$LLM_ENV_CAPTURE"
check "local to cloud: masks saved local key during validation" \
    grep -qx 'LLM_API_KEY=x:' "$LLM_ENV_CAPTURE"
check "local to cloud: validates the cloud model" \
    grep -qx 'SHELLM_MODEL=gpt-5.5' "$LLM_ENV_CAPTURE"

# A cloud switch that FAILS (no key) must leave the working local config
# intact: the wipe is committed only after a cloud key validates. Otherwise
# a plain re-run could not recover the box.
run_init "$WORK/h7c" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
run_init "$WORK/h7c" HEADLONG_PROVIDER=cloud   # no cloud key given
check "failed switch: exits nonzero"                         test "$RC" -ne 0
check "failed switch: local provider still present"          grep -qx "LLM_PROVIDER='openai-compatible'" "$WORK/h7c/.headlong/.env"
check "failed switch: local URL still present"               grep -qx "SHELLM_API_URL='http://127.0.0.1:11434/v1/chat/completions'" "$WORK/h7c/.headlong/.env"

# An existing identity does not make a newly supplied cloud key trusted. If
# that key fails validation, the installer must fail and preserve the entire
# working local route instead of treating it as a transient revalidation.
run_init "$WORK/h7d" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b \
    HEADLONG_LOCAL_API_KEY=local-secret
grep -E '^(LLM_PROVIDER|SHELLM_API_URL|LLM_API_URL|LLM_API_KEY|SHELLM_MODEL)=' \
    "$WORK/h7d/.headlong/.env" > "$WORK/h7d.route.before"
LLM_STUB_RC=1 run_init "$WORK/h7d" \
    HEADLONG_PROVIDER=cloud \
    OPENAI_API_KEY=«redacted:sk-…»
check "invalid cloud key switch: exits nonzero"              test "$RC" -ne 0
grep -E '^(LLM_PROVIDER|SHELLM_API_URL|LLM_API_URL|LLM_API_KEY|SHELLM_MODEL)=' \
    "$WORK/h7d/.headlong/.env" > "$WORK/h7d.route.after"
check "invalid cloud key switch: saved route is unchanged"   cmp -s "$WORK/h7d.route.before" "$WORK/h7d.route.after"

# Prefix-based key correction is staged too. Once the cloud check succeeds,
# the corrected provider variable must be durable for future processes, not
# merely exported in this init process.
run_init "$WORK/h7e" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
run_init "$WORK/h7e" \
    HEADLONG_PROVIDER=cloud \
    OPENAI_API_KEY=sk-or-example-redacted-value
check "corrected-key switch: exits 0"                        test "$RC" -eq 0
check "corrected-key switch: corrected key is persisted"    grep -qx "OPENROUTER_API_KEY='sk-or-example-redacted-value'" "$WORK/h7e/.headlong/.env"
check "corrected-key switch: model follows corrected key"    grep -qx "SHELLM_MODEL='anthropic/claude-sonnet-4.6'" "$WORK/h7e/.headlong/.env"

# ---------------------------------------------------------------------------
# re-run idempotence: the same local config persists again (keyless), and
# an already-configured healthy local endpoint is kept without any
# HEADLONG_PROVIDER hint (the .env alone steers the re-run)
# ---------------------------------------------------------------------------
run_init "$WORK/h8" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
run_init "$WORK/h8"
check "re-run: still exits 0"                                test "$RC" -eq 0
check "re-run: config survives, exactly once per var" \
    test "$(grep -c '^SHELLM_API_URL=' "$WORK/h8/.headlong/.env")" -eq 1

# ---------------------------------------------------------------------------
# A host install keeps its host-reachable URL even when the Docker sandbox is
# on. shellm translates it only for commands executed inside that sandbox.
# ---------------------------------------------------------------------------
HEADLONG_UNSANDBOXED=0 run_init "$WORK/h9" \
    HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:11434 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "sandbox rewrite: exits 0"                             test "$RC" -eq 0
check "host install: persisted url stays host-reachable"     grep -qx "SHELLM_API_URL='http://127.0.0.1:11434/v1/chat/completions'" "$WORK/h9/.headlong/.env"

# A full Headlong container uses host.docker.internal for a server on the
# Docker host, and it probes the same address from inside that container.
HEADLONG_UNSANDBOXED=0 run_init "$WORK/h9b" \
    HEADLONG_FAKE_CONTAINER=1 HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://127.0.0.1:1234 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "container install: exits 0"                           test "$RC" -eq 0
check "container install: persists the Docker host URL"      grep -qx "SHELLM_API_URL='http://host.docker.internal:1234/v1/chat/completions'" "$WORK/h9b/.headlong/.env"
check "container install: probes the Docker host URL"        grep -q 'host.docker.internal:1234/v1/models' "$CURL_MODELS_HITS"

HEADLONG_UNSANDBOXED=0 run_init "$WORK/h9d" \
    HEADLONG_FAKE_CONTAINER=1 HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://local-user:local-pass@127.0.0.1:1234 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "container credential URL: exits 0"                    test "$RC" -eq 0
check_not "container credential URL: rewrite output is redacted" \
    grep -q 'local-user\|local-pass' "$WORK/out"

# A URL whose host merely CONTAINS 'localhost' (or 'host.docker.internal')
# as a substring must survive the container rewrite untouched: only the
# authority host is swapped, never a substring elsewhere.
HEADLONG_UNSANDBOXED=0 run_init "$WORK/h9c" \
    HEADLONG_FAKE_CONTAINER=1 HEADLONG_PROVIDER=local \
    HEADLONG_LOCAL_URL=http://mylocalhost.example:1234 \
    HEADLONG_LOCAL_MODEL=qwen3:8b
check "substring host: exits 0"                              test "$RC" -eq 0
check "substring host: host is left untouched"               grep -qx "SHELLM_API_URL='http://mylocalhost.example:1234/v1/chat/completions'" "$WORK/h9c/.headlong/.env"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
