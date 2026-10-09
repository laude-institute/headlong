#!/usr/bin/env bash
# tests/test_var_secrets.sh — secrets passed to shellm stay off command lines.
#
# Usage: tests/test_var_secrets.sh
#
# Covers:
#   1. `--var NAME` (bare) forwards NAME from shellm's environment into the
#      generated code; `--var NAME` with NAME unset is a clear error.
#   2. While the generated code runs, the secret's value appears in no
#      process's argv (`ps`): not shellm's, not `env`'s, not bash's.
#   3. The shellm-run trajectory row records the command with legacy
#      credential and endpoint `--var NAME=value` values masked, and the
#      literal values are nowhere under the state home.
#
# `llm` is stubbed (canned fenced blocks, no network), same pattern as
# tests/test_inactivity_beacon.sh. Local execution is pinned: shellm would
# otherwise enter Docker mode wherever `docker info` works.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub ----------------------------------------------------------------
mkdir -p "$WORK/script" "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
# Only the main loop passes --thinking; the background run-summary call gets {}.
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=$(( $(cat "$LLM_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$LLM_COUNT"
if [[ -f "$LLM_SCRIPT/$n" ]]; then cat "$LLM_SCRIPT/$n"; else cat "$LLM_SCRIPT/last"; fi
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export LLM_COUNT="$WORK/count"
export LLM_SCRIPT="$WORK/script"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"

# Trajectories must resolve inside the fake state home. An ambient TRAJ_DIR /
# SHELLM_TRAJ_DIR from the caller environment would send the shellm-run row
# outside HEADLONG_HOME, where none of the redaction checks can see it.
unset TRAJ_DIR SHELLM_TRAJ_DIR TRAJ_ID
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

fence() { printf '```bash\n%s\n```\n' "$1"; }

run_shellm() {
    : > "$LLM_COUNT"
    ( cd "$WORK/wd" && "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 2 "$@" ) \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# Generated at runtime so the literals exist nowhere on disk or in any argv
# (this script's own text included) unless something actually leaks them.
SECRET="sk-test-secret-$$-$RANDOM$RANDOM"
LEGACY="sk-legacy-literal-$$-$RANDOM$RANDOM"
PRIVATE_URL="https://example.invalid/private/$$?opaque=$RANDOM"
PRIVATE_DSN="postgresql://user:password@example.invalid/private_$$"
INHERITED_URL="http://127.0.0.1:9/private/$RANDOM"
FILE_URL="http://file.example.invalid/v1/$RANDOM"
COMPACT_APIKEY="api-compact-secret-$$-$RANDOM$RANDOM"
COMPACT_BARE_KEY="bare-key-compact-secret-$$-$RANDOM$RANDOM"
COMPACT_TOKEN="token-compact-secret-$$-$RANDOM$RANDOM"
COMPACT_PASSWORD="password-compact-secret-$$-$RANDOM$RANDOM"
CURL_VALUE="--retry=2"

# --- 1. bare --var with the variable unset is an error ------------------------
unset SECRET_PROBE
run_shellm --var SECRET_PROBE "task"
if [[ $? -ne 0 ]] && grep -q 'SECRET_PROBE: not set' "$WORK/err"; then
    ok "--var NAME with NAME unset fails with a clear message"
else
    bad "--var NAME with NAME unset fails with a clear message" "$(tail -2 "$WORK/err")"
fi

# --- 2. forwarded value reaches the code; nothing carries it in argv ----------
export SECRET_PROBE="$SECRET"
unset SHELLM_API_URL
export LLM_API_URL="$INHERITED_URL"
printf 'SHELLM_API_URL=%s\n' "$FILE_URL" > "$WORK/wd/.env"
fence "printf 'got=%s plain=%s api=%s shellm=%s\\n' \"\$SECRET_PROBE\" \"\$PLAIN\" \"\$LLM_API_URL\" \"\$SHELLM_API_URL\" > '$WORK/probe.txt'
ps -axo args= > '$WORK/ps.txt' 2>/dev/null || ps -eo args= > '$WORK/ps.txt'" > "$WORK/script/1"
fence 'FINAL=done' > "$WORK/script/last"
run_shellm --var SECRET_PROBE --var PLAIN=1 --var "OPENROUTER_API_KEY=$LEGACY" \
    --var "SERVICE_URL=$PRIVATE_URL" --var "DATABASE_DSN=$PRIVATE_DSN" \
    --var "SHELLM_API_URL=$FILE_URL" \
    --var "SERVICE_APIKEY=$COMPACT_APIKEY" --var "APIKEY=$COMPACT_BARE_KEY" \
    --var "ACCESSTOKEN=$COMPACT_TOKEN" \
    --var "PGPASSWORD=$COMPACT_PASSWORD" \
    --var "CURL_OPTS=$CURL_VALUE" "task"
if grep -q "^got=$SECRET plain=1 " "$WORK/probe.txt" 2>/dev/null; then
    ok "bare --var NAME forwards the value into the generated code"
else
    bad "bare --var NAME forwards the value into the generated code" "probe: $(cat "$WORK/probe.txt" 2>/dev/null) err: $(tail -2 "$WORK/err")"
fi
if grep -q " api=$INHERITED_URL shellm=$INHERITED_URL$" "$WORK/probe.txt" 2>/dev/null; then
    ok "process LLM_API_URL wins over file and duplicate extra endpoint aliases"
else
    bad "process LLM_API_URL wins over file and duplicate extra endpoint aliases" "probe: $(cat "$WORK/probe.txt" 2>/dev/null)"
fi
if [[ -z "${SHELLM_API_URL+x}" ]]; then
    ok "the shellm run started with LLM_API_URL only"
else
    bad "the shellm run started with LLM_API_URL only"
fi
if [[ -s "$WORK/ps.txt" ]]; then
    if ! grep -qF "$SECRET" "$WORK/ps.txt"; then
        ok "forwarded secret is in no process's argv while the code runs"
    else
        bad "forwarded secret is in no process's argv while the code runs" "$(grep -F "$SECRET" "$WORK/ps.txt" | cut -c1-160 | head -3)"
    fi
    # The legacy NAME=VALUE form is on shellm's own argv by construction (the
    # caller put it there; shellm's forked subshells repeat that same line).
    # What must not happen is env/docker re-exposing it under a second,
    # different command line. So: at most one DISTINCT argv line carries it,
    # and it is the shellm invocation, not an `env`/`docker` child.
    distinct=$(grep -F "$LEGACY" "$WORK/ps.txt" | sed 's/^ *//' | sort -u)
    n=$(printf '%s\n' "$distinct" | grep -c .)
    if [[ "$n" -le 1 ]] && ! grep -qE '^(env |docker )' <<<"$distinct"; then
        ok "legacy --var NAME=VALUE is not re-exposed by a child process (distinct argv lines: $n)"
    else
        bad "legacy --var NAME=VALUE is not re-exposed by a child process" "$(printf '%s' "$distinct" | cut -c1-120 | head -4)"
    fi
else
    bad "ps snapshot taken from inside the generated code" "ps.txt empty"
fi

# --- 3. recorded command is redacted; literal value nowhere in state ----------
row=$(grep -rh '"type":"shellm-run"' "$HEADLONG_HOME" 2>/dev/null | tail -1)

if [[ -n "$row" ]]; then
    ok "shellm-run row is recorded under the state home"
else
    bad "shellm-run row is recorded under the state home" "no shellm-run row under $HEADLONG_HOME; the redaction checks below cannot pass without it"
fi
if [[ -n "$row" ]] && grep -qF 'OPENROUTER_API_KEY=<redacted>' <<<"$row" \
    && grep -qF 'SERVICE_URL=<redacted>' <<<"$row" \
    && grep -qF 'DATABASE_DSN=<redacted>' <<<"$row" \
    && grep -qF 'SERVICE_APIKEY=<redacted>' <<<"$row" \
    && grep -qF 'APIKEY=<redacted>' <<<"$row" \
    && grep -qF 'ACCESSTOKEN=<redacted>' <<<"$row" \
    && grep -qF 'PGPASSWORD=<redacted>' <<<"$row" \
    && ! grep -qF "$LEGACY" <<<"$row" && ! grep -qF "$PRIVATE_URL" <<<"$row" \
    && ! grep -qF "$PRIVATE_DSN" <<<"$row" \
    && ! grep -qF "$COMPACT_APIKEY" <<<"$row" \
    && ! grep -qF "$COMPACT_BARE_KEY" <<<"$row" \
    && ! grep -qF "$COMPACT_TOKEN" <<<"$row" \
    && ! grep -qF "$COMPACT_PASSWORD" <<<"$row"; then
    ok "shellm-run row masks compact credentials, URL, and DSN --var values"
else
    bad "shellm-run row masks compact credentials, URL, and DSN --var values" "redacted fields missing"
fi
if grep -qF -- '--var SECRET_PROBE --var PLAIN=1' <<<"$row" \
    && grep -qF -- "--var CURL_OPTS=$CURL_VALUE" <<<"$row"; then
    ok "shellm-run row keeps bare names and CURL_OPTS readable"
else
    bad "shellm-run row keeps bare names and CURL_OPTS readable" "$(printf '%s' "$row" | cut -c1-200)"
fi
if ! grep -qF "$INHERITED_URL" <<<"$row"; then
    ok "inherited endpoint is absent from the shellm command record"
else
    bad "inherited endpoint is absent from the shellm command record"
fi
hits=$(grep -rlF "$LEGACY" "$HEADLONG_HOME" "$WORK/wd" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" -eq 0 ]]; then
    ok "legacy literal value is nowhere under the state home or workdir"
else
    bad "legacy literal value is nowhere under the state home or workdir" "$(grep -rlF "$LEGACY" "$HEADLONG_HOME" "$WORK/wd" | head -3)"
fi
hits=$(grep -rlF "$SECRET" "$HEADLONG_HOME" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" -eq 0 ]]; then
    ok "forwarded secret is nowhere under the state home"
else
    bad "forwarded secret is nowhere under the state home" "$(grep -rlF "$SECRET" "$HEADLONG_HOME" | head -3)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
