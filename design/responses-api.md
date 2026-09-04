# OpenAI Responses completion protocol

Status: implemented 2026-09-01.

## Scope

Headlong's completion boundary remains `bin/llm`. Chat Completions remains the
default. Operators opt into the OpenAI Responses create protocol with
`LLM_API_FORMAT=responses` for the `openai`, `openrouter`, or
`openai-compatible` providers.

This change covers synchronous buffered and SSE response creation, including
reasoning summaries, function call items and outputs, structured and
multimodal input items, terminal status and errors, usage, and continuation.
Response retrieval/deletion/cancellation, input-item listing, Conversations,
background responses, and WebSocket mode are separate lifecycle work.

## Wire contract

- Native OpenAI defaults to `https://api.openai.com/v1/responses` in Responses
  mode. OpenRouter defaults to `https://openrouter.ai/api/v1/responses`.
  `openai-compatible` still requires the exact `LLM_API_URL` endpoint.
- The existing messages input is passed as the Responses `input` array without
  reshaping. This preserves typed input/output items, images, files, assistant
  phases, reasoning items, function calls, and `function_call_output` items.
- The system prompt maps to `instructions`, the token cap maps to
  `max_output_tokens`, and an explicit thinking level maps to
  `reasoning.effort` with an automatic summary.
- `LLM_RESPONSES_BODY_FILE` may name a JSON object containing other synchronous
  create fields. `bin/llm` owns and overwrites `model`, `input`, `instructions`,
  `max_output_tokens`, `stream`, and `previous_response_id` so command-line and
  continuation semantics remain deterministic. Conversation state is rejected
  because it conflicts with this continuation contract.
- Every create requests `reasoning.encrypted_content`, preserving exact
  reasoning-item replay for stateless and Zero Data Retention paths while
  retaining any other caller-supplied `include` values.
- `LLM_PREVIOUS_RESPONSE_ID` adds stateful continuation.
- `LLM_RESPONSE_FILE`, when set, receives the complete terminal Response object
  or provider error envelope through an atomic mode-0600 write. It is the
  machine-readable channel for response IDs, all output items, function calls,
  encrypted reasoning, status, errors, and usage.

The human-output contract does not change: visible `output_text` is stdout,
reasoning summaries are stderr, and `--raw` prints the buffered API object.
A function-only response is a successful protocol response even though stdout
is empty; callers consume its items from `LLM_RESPONSE_FILE`.

## Streaming and failure semantics

The SSE handler emits text and reasoning deltas as they arrive, records the
terminal response from `response.completed`, `response.incomplete`, or
`response.failed`, and maps Responses usage into the existing usage record.
Incomplete responses warn with their reason. Failed responses and `error`
events fail the call.

Retries remain legal only before protocol output is emitted. A terminal output
item counts as output even when it is a function call with no visible text.
After a text, reasoning, or output-item event, a truncated or failed stream is
never replayed automatically.

## shellm continuation

Responses mode keeps completion state only for the current `shellm` process:

1. The first call sends the trajectory-derived context in full.
2. Later calls send only newly appended user-side context plus the stable
   instructions and the previous response ID.
3. In parallel, shellm retains the original input and every terminal output
   item. This exact replay chain preserves encrypted reasoning and assistant
   `phase` values for stateless endpoints and Zero Data Retention accounts.
4. If a continuation is rejected specifically because the previous response
   cannot be referenced, before any output is emitted, shellm retries once with
   the replay chain and remains stateless for the rest of the run.
5. A resumed process starts a new chain from the durable trajectory. Remote
   response IDs are not persisted as durable trajectory state.

OpenRouter's Responses endpoint is stateless and therefore starts directly in
replay mode. Native OpenAI and generic compatible endpoints use automatic
stateful continuation with the safe replay fallback.

The existing thinking-text empty-response workaround remains the Chat
Completions behavior. In Responses mode, an incomplete reasoning-only Response
continues through its response ID or exact output-item replay instead of
turning a reasoning summary into an invented assistant message.

## Verification

Hermetic tests pin request JSON, endpoint selection, pass-through input,
extra-body validation and precedence, buffered extraction, terminal sidecar
permissions, response status and usage, SSE event classes, function-only
success, stateful shellm deltas, stateless replay, continuation fallback, and
unchanged Chat behavior. The implementation is additionally smoke-tested
against native OpenAI and an independent OpenAI-compatible Responses endpoint.
