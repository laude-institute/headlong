#!/usr/bin/env bash
# Test the shipped redactor with synthetic keys only, never inherited secrets.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unset ANTHROPIC_API_KEY LLM_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY OPENCODE_API_KEY
awk '/^redact_sensitive\(\) \{$/,/^\}$/' "$REPO/bin/shellm" > "$WORK/fn"
[[ -s "$WORK/fn" ]] || { echo "FAIL: no redactor extracted"; exit 1; }
# shellcheck disable=SC1091
source "$WORK/fn"

pass=0 fail=0
expect() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        printf 'FAIL: %s\n' "$name"
    fi
}
vars=(ANTHROPIC_API_KEY LLM_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY OPENCODE_API_KEY)
for var in "${vars[@]}"; do
    marker='<redacted-api-key>'
    [[ "$var" != ANTHROPIC_API_KEY ]] || marker='<redacted-anthropic-key>'
    export "$var=abc*def"
    expect "$var star stays literal" "$(redact_sensitive 'abc*def abcXYZdef abc*def')" "$marker abcXYZdef $marker"
    export "$var=a?c"
    expect "$var question mark stays literal" "$(redact_sensitive 'a?c abc a c')" "$marker abc a c"
    export "$var=key[ab]end"
    expect "$var bracket key is hidden" "$(redact_sensitive 'key[ab]end keyaend keybend')" "$marker keyaend keybend"
    export "$var=key\end"
    expect "$var backslash stays literal" "$(redact_sensitive 'key\end keyend')" "$marker keyend"
    export "$var=plain-key"
    expect "$var plain repeated key" "$(redact_sensitive 'plain-key/plain-key')" "$marker/$marker"
    export "$var="
    expect "$var empty key" "$(redact_sensitive 'harmless text')" 'harmless text'
    unset "$var"
done
expect 'unset keys' "$(redact_sensitive 'harmless text')" 'harmless text'
expect 'anthropic prefix fallback' "$(redact_sensitive 'token sk-ant-synthetic_123.abc tail')" 'token <redacted-anthropic-key> tail'
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
