# agent loop

source: `lib/ah/loop.tl`

## lifecycle

`loop.run_agent()` is the core loop. it takes a database handle, system
prompt, model, initial prompt, and an event callback.

```
user prompt
  → build API messages from conversation ancestry
  → drain steering queue
  → check compaction need
  → api.stream() (Claude Messages API)
  → process response
    → text blocks: emit text_delta events
    → tool_use blocks: execute tools, collect results
  → persist assistant message + tool results to db
  → loop detection check
  → repeat (if stop_reason == "tool_use")
  → exit (if stop_reason == "end_turn", error, interrupted, budget_exceeded)
```

## API interaction

`api.tl` handles streaming requests to the Claude Messages API.

- endpoint: `https://api.anthropic.com/v1/messages`
- default model: `claude-opus-4-6`
- aliases: `sonnet` → `claude-sonnet-4-5-20250929`, `opus` → `claude-opus-4-6`, `haiku` → `claude-haiku-4-5-20251001`
- max retries: 3, with exponential backoff (1s base, 60s max)
- supports OAuth tokens (Claude Max) and API keys
- adds `cache_control` breakpoint on the last content block for prompt caching

## tool dispatch

when the response contains `tool_use` blocks, the loop:

1. emits `tool_call_start` for each tool.
2. calls `tools.execute()` with the tool input.
3. records tool output and duration in the database.
4. truncates output for the API (full output preserved in db).
5. emits `tool_call_end` with result.
6. creates a user message with all `tool_result` blocks.

tools execute sequentially within a turn. all tool calls from a single
response are executed before the next API call.

## loop detection

the loop tracks turn signatures (tool names + key parameters + edit content).
consecutive identical signatures trigger:

- **3 identical turns**: a steering message is injected telling the agent
  it appears stuck.
- **5 identical turns**: the loop breaks with `end_turn`.

## compaction

when `input_tokens / context_limit > 0.8`, compaction triggers:

1. sends the full conversation to a separate API call with a summarization prompt.
2. replaces the API message history with the summary.
3. persists the summary as a `[COMPACTION SUMMARY]` user message in the db.
4. the full conversation is always preserved in the database.

context limit is 200k tokens for all current models.

## interruption

ctrl+c sets a global `interrupted` flag. the loop checks this:
- between iterations (clean exit).
- mid-stream via `is_interrupted` callback passed to `api.stream()`.
- partial responses are persisted before exit.
- running tool processes are sent SIGTERM → SIGKILL.

## budget enforcement

`--max-tokens N` sets a cumulative token budget (input + output). when
exceeded, the loop exits with `budget_exceeded` stop reason.

## events

the loop emits structured events via callback: `agent_start`, `agent_end`,
`api_call_start`, `api_call_end`, `tool_call_start`, `tool_call_end`,
`text_delta`, `error`, `retry`, `state_change`, `steering_received`,
`compaction_triggered`, `compaction_complete`.

events are both emitted to the callback (for CLI display) and logged to
the database events table.

## dangling tool_use repair

when rebuilding API messages from history, the loop detects assistant
messages with `tool_use` blocks not followed by matching `tool_result`
messages. it injects synthetic error results so the API call succeeds.
this handles corruption from crashes or interrupted sessions.
