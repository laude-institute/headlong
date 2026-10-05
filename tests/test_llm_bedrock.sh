#!/usr/bin/env bash
# tests/test_llm_bedrock.sh — the bedrock provider (Claude in Amazon Bedrock,
# the Messages API on bedrock-mantle) against a local mock server.
#
# Usage: tests/test_llm_bedrock.sh
#
# Checks: anthropic.* model ids route to bedrock; the default endpoint is
# built from AWS_REGION; a bearer token goes in x-api-key; without one, the
# request is SigV4-signed for service bedrock-mantle with the session token
# header, and no secret appears on curl's argv; the body is the first-party
# Messages body (model, thinking); plain and streamed (SSE) responses parse;
# usage lands on the ledger as provider bedrock with cache reads; output caps
# and thinking support follow the model behind the prefix; and shellm masks
# AWS secrets. No network, no docker.

set -uo pipefail
unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY LLM_PROVIDER LLM_API_URL \
    AWS_BEARER_TOKEN_BEDROCK AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION \
    IDENTITY_DIR IDENTITY_NAME 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
has() { if printf '%s' "$2" | grep -F -- "$3" >/dev/null; then ok "$1"; else bad "$1" "missing '$3' in: $(printf '%s' "$2" | head -c 400)"; fi; }
hasnt() { if printf '%s' "$2" | grep -F -- "$3" >/dev/null; then bad "$1" "unexpected '$3'"; else ok "$1"; fi; }

command -v python3 >/dev/null || { echo "FAIL python3 not found"; exit 1; }
WORK=$(mktemp -d)
cleanup() { [[ -n "${SRV:-}" ]] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
export HOME="$WORK/home" HEADLONG_HOME="$WORK/home/.headlong"; mkdir -p "$HEADLONG_HOME"

cat > "$WORK/srv.py" <<'PY'
import http.server, json, sys, os
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0))).decode()
        n = len(os.listdir(out))
        json.dump({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": json.loads(body)},
                  open(f"{out}/req-{n}.json", "w"))
        req = json.loads(body)
        usage = {"input_tokens": 120, "output_tokens": 7, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 500}
        if req.get("stream"):
            self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
            ev = [("message_start", {"type": "message_start", "message": {"usage": usage}}),
                  ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                  ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "streamed hello"}}),
                  ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                  ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 7}}),
                  ("message_stop", {"type": "message_stop"})]
            for name, data in ev:
                self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
        else:
            resp = {"type": "message", "role": "assistant", "content": [{"type": "text", "text": "plain hello"}],
                    "stop_reason": "end_turn", "usage": usage}
            b = json.dumps(resp).encode()
            self.send_response(200); self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(f"{out}/../port", "w").write(str(s.server_port))
s.serve_forever()
PY
mkdir -p "$WORK/reqs"
python3 "$WORK/srv.py" "$WORK/reqs" & SRV=$!
for _ in $(seq 1 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "$WORK/port")/anthropic/v1/messages"
last() { ls -t "$WORK"/reqs/req-*.json | head -1; }

# ── routing and the default endpoint ─────────────────────────────────────────
out=$(AWS_REGION=eu-west-1 llm -m anthropic.claude-opus-5-5 --print-request "hi" 2>&1) || true
if printf '%s' "$out" | grep -q 'bedrock-mantle.eu-west-1.api.aws/anthropic/v1/messages'; then ok "default endpoint from AWS_REGION"
else
    # --print-request may not exist; check via a missing-credentials error instead
    out=$(AWS_REGION=eu-west-1 llm -m anthropic.claude-opus-5-5 "hi" 2>&1)
    has "anthropic.* routes to bedrock (credential error names Bedrock)" "$out" "Bedrock needs AWS_BEARER_TOKEN_BEDROCK"
fi

# ── bearer token, plain response ─────────────────────────────────────────────
export LLM_USAGE_LEDGER="$WORK/ledger.jsonl"
out=$(AWS_BEARER_TOKEN_BEDROCK=tok-123 LLM_API_URL="$URL" llm --no-stream -m anthropic.claude-opus-5-5 "hello" 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "bearer call succeeds" || bad "bearer call succeeds" "rc=$rc"
has "plain response text" "$out" "plain hello"
r=$(cat "$(last)")
has "bearer token in x-api-key" "$(jq -r '.headers["x-api-key"] // ""' <<<"$r")" "tok-123"
hasnt "no SigV4 with a bearer token" "$(jq -r '.headers.authorization // ""' <<<"$r")" "AWS4-HMAC-SHA256"
has "anthropic-version header" "$(jq -r '.headers["anthropic-version"] // ""' <<<"$r")" "2023-06-01"
has "model id in the body as given" "$(jq -r '.body.model' <<<"$r")" "anthropic.claude-opus-5-5"
has "ledger records provider bedrock" "$(tail -1 "$LLM_USAGE_LEDGER")" '"provider":"bedrock"'
has "ledger records cache reads" "$(tail -1 "$LLM_USAGE_LEDGER")" '"cache_tok":3000'
has "ledger counts cache writes as input (120 + 500)" "$(tail -1 "$LLM_USAGE_LEDGER")" '"in_tok":620'

# ── prompt caching breakpoints ───────────────────────────────────────────────
AWS_BEARER_TOKEN_BEDROCK=t LLM_API_URL="$URL" llm --no-stream -s "You are a system prompt." -m anthropic.claude-opus-5-5 "hello" >/dev/null 2>&1
r=$(cat "$(last)")
has "cache breakpoint on the system prompt" "$(jq -c '.body.system' <<<"$r")" '"cache_control":{"type":"ephemeral"}'
has "system text kept" "$(jq -c '.body.system' <<<"$r")" '"text":"You are a system prompt."'
has "cache breakpoint on the last message" "$(jq -c '.body.messages[-1].content[-1]' <<<"$r")" '"cache_control":{"type":"ephemeral"}'
has "last message text kept" "$(jq -c '.body.messages[-1].content[-1]' <<<"$r")" '"text":"hello"'
msgs='[{"role":"user","content":"first"},{"role":"assistant","content":"reply"},{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}]'
AWS_BEARER_TOKEN_BEDROCK=t LLM_API_URL="$URL" llm --no-stream -M "$msgs" -m anthropic.claude-opus-5-5 >/dev/null 2>&1
r=$(cat "$(last)")
eq_n=$(jq '[.body.messages[] | (if (.content|type)=="array" then .content[] else empty end) | select(.cache_control)] | length' <<<"$r")
[[ "$eq_n" == 1 ]] && ok "exactly one message breakpoint, on the last block" || bad "exactly one message breakpoint" "got $eq_n"
has "earlier messages untouched" "$(jq -c '.body.messages[0].content' <<<"$r")" '"first"'
AWS_BEARER_TOKEN_BEDROCK=t LLM_PROMPT_CACHE=0 LLM_API_URL="$URL" llm --no-stream -s "sys" -m anthropic.claude-opus-5-5 "hello" >/dev/null 2>&1
hasnt "LLM_PROMPT_CACHE=0 turns breakpoints off" "$(jq -c '.body' "$(last)")" 'cache_control'
ANTHROPIC_API_KEY=k LLM_API_URL="$URL" llm --no-stream -s "sys" -m claude-opus-5-5 "hello" >/dev/null 2>&1
has "first-party Anthropic gets breakpoints too" "$(jq -c '.body.system' "$(last)")" 'cache_control'
OPENAI_API_KEY=k LLM_API_URL="$URL" llm --no-stream -s "sys" -m gpt-5 "hello" >/dev/null 2>&1
hasnt "OpenAI-format requests get no cache_control" "$(jq -c '.body' "$(last)")" 'cache_control'

# ── SigV4, streamed response, thinking ───────────────────────────────────────
out=$(AWS_ACCESS_KEY_ID=AKIDEXAMPLE AWS_SECRET_ACCESS_KEY=sekret/xyz AWS_SESSION_TOKEN=sess-tok AWS_REGION=us-west-2 \
    LLM_API_URL="$URL" llm --thinking -m anthropic.claude-opus-5-5 "hello" 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "SigV4 streamed call succeeds" || bad "SigV4 streamed call succeeds" "rc=$rc"
has "streamed response text" "$out" "streamed hello"
r=$(cat "$(last)")
auth=$(jq -r '.headers.authorization // ""' <<<"$r")
has "SigV4 signature" "$auth" "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"
has "signed for region and service bedrock-mantle" "$auth" "/us-west-2/bedrock-mantle/aws4_request"
has "session token header" "$(jq -r '.headers["x-amz-security-token"] // ""' <<<"$r")" "sess-tok"
has "adaptive thinking sent (model behind the prefix is known)" "$(jq -c '.body.thinking // {}' <<<"$r")" '"type":"adaptive"'
# No secret on argv: run curl through a recorder.
mkdir -p "$WORK/shim"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$WORK/argv" "$(command -v curl)" > "$WORK/shim/curl"
chmod +x "$WORK/shim/curl"
PATH="$WORK/shim:$PATH" AWS_ACCESS_KEY_ID=AKIDEXAMPLE AWS_SECRET_ACCESS_KEY=sekret/xyz AWS_SESSION_TOKEN=sess-tok \
    LLM_API_URL="$URL" llm -m anthropic.claude-opus-5-5 "hello" >/dev/null 2>&1
hasnt "secret key not on curl's argv" "$(cat "$WORK/argv" 2>/dev/null)" "sekret/xyz"
hasnt "session token not on curl's argv" "$(cat "$WORK/argv" 2>/dev/null)" "sess-tok"

# ── model caps behind the prefix ─────────────────────────────────────────────
mt=$(AWS_BEARER_TOKEN_BEDROCK=t LLM_API_URL="$URL" llm -m anthropic.claude-opus-5-5 "x" >/dev/null 2>&1; jq -r '.body.max_tokens' "$(last)")
mt2=$(ANTHROPIC_API_KEY=k LLM_API_URL="$URL" llm -m claude-opus-5-5 "x" >/dev/null 2>&1; jq -r '.body.max_tokens' "$(last)")
[[ -n "$mt" && "$mt" == "$mt2" ]] && ok "output cap matches the first-party model ($mt)" || bad "output cap matches the first-party model" "bedrock=$mt first-party=$mt2"
[[ "$mt2" == 128000 ]] && ok "current Claude models get their 128K output cap, not the 4096 fallback" || bad "current Claude models get their 128K output cap" "got $mt2"

# ── bedrock-invoke: InvokeModel on bedrock-runtime ───────────────────────────
INV="http://127.0.0.1:$(cat "$WORK/port")/model/us.anthropic.claude-opus-5-5/invoke"
out=$(AWS_BEARER_TOKEN_BEDROCK=tok-456 LLM_API_URL="$INV" llm --thinking -m us.anthropic.claude-opus-5-5 "hello" 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "invoke call succeeds" || bad "invoke call succeeds" "rc=$rc"
has "invoke: response parsed (forced non-streaming)" "$out" "plain hello"
r=$(cat "$(last)")
has "invoke: bearer in Authorization" "$(jq -r '.headers.authorization // ""' <<<"$r")" "Bearer tok-456"
has "invoke: anthropic_version in the body" "$(jq -r '.body.anthropic_version // ""' <<<"$r")" "bedrock-2023-05-31"
eq_model=$(jq -r '.body | has("model") or has("stream")' <<<"$r")
[[ "$eq_model" == false ]] && ok "invoke: no model or stream field in the body" || bad "invoke: no model or stream field in the body"
has "invoke: thinking kept" "$(jq -c '.body.thinking // {}' <<<"$r")" '"type":"adaptive"'
has "invoke: cache breakpoint survives the InvokeModel reshaping" "$(jq -c '.body.messages[-1]' <<<"$r")" 'cache_control'
imt=$(jq -r '.body.max_tokens' <<<"$r")
(( imt <= 32000 )) && ok "invoke: output cap held to 32000 for non-streaming ($imt)" || bad "invoke: output cap held" "$imt"
out=$(AWS_REGION=us-west-1 llm -m us.anthropic.claude-opus-5-5 "hi" 2>&1)
has "invoke: no credentials names Bedrock" "$out" "Bedrock needs AWS_BEARER_TOKEN_BEDROCK"
has "invoke: ledger provider" "$(tail -1 "$LLM_USAGE_LEDGER")" '"provider":"bedrock-invoke"'

# ── shellm masks AWS secrets ─────────────────────────────────────────────────
masked=$(AWS_SECRET_ACCESS_KEY=sekret/xyz AWS_BEARER_TOKEN_BEDROCK=tok-123 bash -c '
    source <(sed -n "/^redact_sensitive() {/,/^}/p" "$1"); redact_sensitive "a sekret/xyz b tok-123 c"' _ "$REPO/bin/shellm")
hasnt "shellm masks the secret key" "$masked" "sekret/xyz"
hasnt "shellm masks the bearer token" "$masked" "tok-123"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
