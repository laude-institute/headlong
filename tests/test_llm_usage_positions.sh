#!/usr/bin/env bash
# Offline regression; copy into upstream tests/ before running.
# Exercise the real CLI, with curl stubbed; no model or credentials needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == -o ]] && out="$arg"
    prev="$arg"
done
if [[ -n "$out" ]]; then
    cat "$FIXTURE" > "$out"
    printf 200
else
    printf 'data: %s\n\n' "$(jq -c . "$FIXTURE")"
    printf 'data: [DONE]\n\n'
fi
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" HOME="$WORK/home" HEADLONG_HOME="$WORK/home"
export LLM_USAGE_LEDGER=/dev/null LLM_USAGE_FILE="$WORK/usage.json" LLM_RETRIES=0
export LLM_API_URL=http://127.0.0.1:9/fixture FIXTURE="$WORK/response.json"
export ANTHROPIC_API_KEY=fixture OPENCODE_API_KEY=fixture GEMINI_API_KEY=fixture
unset TRAJ_ID TRAJ_DIR IDENTITY_DIR LLM_PROVIDER LLM_MODEL SHELLM_MODEL LLM_STOP_AFTER_CODE_BLOCK
cd "$WORK" || exit 1
pass=0; fail=0
for provider in openai-compatible gemini anthropic opencode; do
    for transport in --stream --no-stream; do
        case "$provider:$transport" in anthropic:--stream|opencode:--stream) continue ;; esac
        for shape in missing_reasoning zero_reasoning reasoning missing_input missing_output no_cache; do
            jq -nc --arg p "$provider" --arg s "$shape" '
                {i:2282,o:113,t:17,c:2141}
                | if $s=="missing_reasoning" then del(.t)
                  elif $s=="zero_reasoning" then .t=0
                  elif $s=="missing_input" then del(.i)
                  elif $s=="missing_output" then del(.o)
                  elif $s=="no_cache" then del(.t,.c) else . end
                | with_entries(select(.value!=null))
                | {expected:(. | with_entries(.key |= ({i:"in_tok",o:"out_tok",t:"think_tok",c:"cache_tok"}[.]))), v:.}
                | . as $x
                | if $p=="gemini" then
                    {candidates:[{content:{parts:[{text:"ok"}]},finishReason:"STOP"}],usageMetadata:{promptTokenCount:$x.v.i,candidatesTokenCount:$x.v.o,thoughtsTokenCount:$x.v.t,cachedContentTokenCount:$x.v.c}}
                  elif ($p=="anthropic" or $p=="opencode") then
                    {content:[{type:"text",text:"ok"}],stop_reason:"end_turn",usage:{input_tokens:$x.v.i,output_tokens:$x.v.o,cache_read_input_tokens:$x.v.c}}
                  else
                    {choices:[{message:{content:"ok"},delta:{content:"ok"},finish_reason:"stop"}],usage:{prompt_tokens:$x.v.i,completion_tokens:$x.v.o,completion_tokens_details:{reasoning_tokens:$x.v.t},prompt_tokens_details:{cached_tokens:$x.v.c}}}
                  end
                | {response:.,expected:($x.expected | if ($p=="anthropic" or $p=="opencode") then del(.think_tok) else . end)}
            ' > "$WORK/case.json"
            jq '.response' "$WORK/case.json" > "$FIXTURE"
            rm -f "$LLM_USAGE_FILE"
            if LLM_PROVIDER="$provider" "$REPO/bin/llm" -m fixture "$transport" probe > "$WORK/stdout" 2> "$WORK/stderr" \
               && jq -e --slurpfile c "$WORK/case.json" '. == $c[0].expected' "$LLM_USAGE_FILE" >/dev/null 2>&1; then
                pass=$((pass+1))
            else
                fail=$((fail+1))
                printf 'FAIL %s %s %s: ' "$provider" "$transport" "$shape"
                cat "$LLM_USAGE_FILE" 2>/dev/null || cat "$WORK/stderr"
            fi
        done
    done
done
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
