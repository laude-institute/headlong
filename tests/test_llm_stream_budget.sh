#!/usr/bin/env bash
# Wall-clock budget per call shape (issue: a healthy 3.5 MB streaming answer
# was cut dead at LLM_MAX_TIME=600 with curl 28 and could not be retried).
# The stub records the curl argv for every call, so the assertions read what
# the curl command would actually receive:
#   - streaming default (LLM_STREAM_MAX_TIME=0) passes NO --max-time at all
#   - streaming with LLM_STREAM_MAX_TIME=90 passes exactly --max-time 90
#   - non-streaming keeps the flat LLM_MAX_TIME ceiling regardless

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_ARGV"
mode=$(cat "$CURL_MODE")
case "$mode" in
    stream)
        printf 'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n'
        ;;
    http-200)
        out_file=""
        prev=""
        for a in "$@"; do
            [[ "$prev" == "-o" ]] && out_file="$a"
            prev="$a"
        done
        printf '{"choices":[{"message":{"content":"ok"}}]}' > "$out_file"
        printf '200'
        ;;
esac
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export OPENROUTER_API_KEY="test-key"
export HEADLONG_HOME="$WORK/home"
mkdir -p "$HEADLONG_HOME"
# Do not inherit a caller's overrides: these cases assert on the script
# defaults (LLM_MAX_TIME=600, no stream ceiling), so an exported value would
# silently win and make a clean-env run fail in a polluted shell.
unset LLM_MAX_TIME LLM_STREAM_MAX_TIME LLM_SPEED_LIMIT LLM_SPEED_TIME LLM_CONNECT_TIMEOUT
export CURL_ARGV="$WORK/argv" CURL_MODE="$WORK/mode"

LLM="$REPO/bin/llm"
MODEL="openai/gpt-oss-120b"

# --- streaming default: no wall clock on the stream ------------------------
: > "$CURL_ARGV"; printf 'stream' > "$CURL_MODE"
LLM_STREAM_MAX_TIME=0 "$LLM" -m "$MODEL" "say ok" >/dev/null 2>"$WORK/stderr"
check "stream default exits 0"        test "$?" -eq 0
check_not "stream default has no --max-time" grep -q -- '--max-time' "$CURL_ARGV"
check "stream default keeps the speed guard" grep -q -- '--speed-time' "$CURL_ARGV"
check "stream default keeps --connect-timeout" grep -q -- '--connect-timeout' "$CURL_ARGV"

# --- streaming with an explicit budget: exactly that many seconds ----------
: > "$CURL_ARGV"; printf 'stream' > "$CURL_MODE"
LLM_STREAM_MAX_TIME=90 "$LLM" -m "$MODEL" "say ok" >/dev/null 2>"$WORK/stderr"
check "stream budget exits 0"         test "$?" -eq 0
check "stream budget passes --max-time 90" grep -q -- '--max-time 90' "$CURL_ARGV"
check_not "stream budget passes no other ceiling" grep -qE -- '--max-time (600|10)[0-9]?' "$CURL_ARGV"

# --- non-streaming: the flat ceiling survives ------------------------------
: > "$CURL_ARGV"; printf 'http-200' > "$CURL_MODE"
"$LLM" -m "$MODEL" --no-stream "say ok" >/dev/null 2>"$WORK/stderr"
check "non-stream exits 0"            test "$?" -eq 0
check "non-stream keeps --max-time 600" grep -q -- '--max-time 600' "$CURL_ARGV"

# --- non-streaming with its own override -----------------------------------
: > "$CURL_ARGV"; printf 'http-200' > "$CURL_MODE"
LLM_MAX_TIME=120 "$LLM" -m "$MODEL" --no-stream "say ok" >/dev/null 2>"$WORK/stderr"
check "non-stream honours LLM_MAX_TIME=120" grep -q -- '--max-time 120' "$CURL_ARGV"

# --- a stream budget of 0 must never pass --max-time 0 ---------------------
: > "$CURL_ARGV"; printf 'stream' > "$CURL_MODE"
LLM_STREAM_MAX_TIME=0 "$LLM" -m "$MODEL" "say ok" >/dev/null 2>"$WORK/stderr"
check_not "0 is not passed as a ceiling" grep -q -- '--max-time' "$CURL_ARGV"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
