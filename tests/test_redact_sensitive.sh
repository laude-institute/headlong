#!/usr/bin/env bash
# tests/test_redact_sensitive.sh — redact_sensitive masks every provider key.
#
# Usage: tests/test_redact_sensitive.sh
#
# The function is extracted from bin/shellm and exercised directly (sourcing
# the whole script would run it). Every provider key env var's value must
# come back masked, and the sk-ant- pattern is masked even with no env var
# carrying the value.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

eval "$(sed -n '/^redact_sensitive()/,/^}/p' "$REPO/bin/shellm")"
if ! declare -f redact_sensitive >/dev/null; then
    bad "redact_sensitive extracted from bin/shellm"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

for var in ANTHROPIC_API_KEY LLM_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY \
           GEMINI_API_KEY OPENCODE_API_KEY; do
    secret="key-$$-$RANDOM$RANDOM"
    export "$var=$secret"
    out=$(redact_sensitive "before $secret after")
    if [[ "$out" != *"$secret"* && "$out" == *redacted* ]]; then
        ok "$var value is masked"
    else
        bad "$var value is masked" "$out"
    fi
    unset "$var"
done

out=$(redact_sensitive "token sk-ant-abc123XYZ here")
if [[ "$out" == *'<redacted-anthropic-key>'* && "$out" != *sk-ant-abc123XYZ* ]]; then
    ok "sk-ant- pattern is masked without the env var"
else
    bad "sk-ant- pattern is masked without the env var" "$out"
fi


# Credential shapes that arrive as text (a person pastes them) carry no env var
# to match against, so the shape rules are what catch them. These are the
# shapes that were actually found in the mind log during the 2026-09-25
# exposure audit.
shape_case() {
    local name="$1" secret="$2" out
    out=$(redact_sensitive "before $secret after")
    if [[ "$out" != *"$secret"* && "$out" == *redacted* ]]; then
        ok "$name shape is masked"
    else
        bad "$name shape is masked" "$out"
    fi
}
shape_case "github-classic"    "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
shape_case "github-fine"       "github_pat_AAAAAAAAAAAAAAAAAAAAAA_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
shape_case "slack-cookie"      "xoxc-123456789012-123456789012-abcdef0123456789abcdef0123456789abcdef"
shape_case "slack-app"         "xoxe-1-0000000000-1234567890abcdef-abcdefghijklmnopqrstuv"
shape_case "huggingface"       "hf_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
shape_case "google"            "AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYzAbCdEf"
shape_case "aws"               "AKIAIOSFODNN7EXAMPLE"
shape_case "jwt"               "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghij0123456789"
shape_case "openai-project"    "sk-proj-0123456789abcdef.0123456789abcdef0123456789abcdef0123456789abcdef"
shape_case "basic-auth-url"    "https://user:SuperSecretPass123@host.example"

# A credential env var outside the provider set is masked by value too. This
# uses TWILIO_AUTH_TOKEN, which has no shape rule of its own, so a clean result
# here is the value pass alone and not a lucky pattern match. The assertion is
# on the whole var value: value masking matches the value the env var holds,
# not some substring of it.
secret="twilio-$$-$RANDOM$RANDOM$RANDOM$RANDOM-credential"
export TWILIO_AUTH_TOKEN="$secret"
out=$(redact_sensitive "before $secret after")
if [[ "$out" != *"$secret"* && "$out" == *redacted* ]]; then
    ok "TWILIO_AUTH_TOKEN value is masked"
else
    bad "TWILIO_AUTH_TOKEN value is masked" "$out"
fi
unset TWILIO_AUTH_TOKEN

# Prose that merely resembles a token shape must come back unchanged.
plain="see https://github.com/headlong42/headlong/pull/8 and http://host.example:8080/api plus xox-shaped mention hf_word and sk- short note 12345"
out=$(redact_sensitive "$plain")
if [[ "$out" == "$plain" ]]; then
    ok "prose that resembles a token is left alone"
else
    bad "prose that resembles a token is left alone" "$out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
