# Convergence with consensus agent architecture

Gap analysis comparing `ah` against the emerging three-layer architecture
identified across pi-mono, attractor, and cxdb. Each section describes
what `ah` does today, what the consensus pattern looks like, and what
convergence requires.

---

## 1. Three-layer separation

### Consensus pattern

Strict dependency boundaries between three layers:
- **Foundation**: LLM abstraction with zero internal dependencies.
- **Agent core**: Loop, session persistence, tool dispatch.
- **Application**: CLI, TUI, or other user-facing interface.

Pi-mono implements this as three npm packages. Attractor mirrors it in
three specification documents. Each layer depends only on layers below it.

### Current state

`ah` has the right modules but the boundaries leak:

- **`api.tl` depends on `tools.tl`** (line 6: `local tools_mod = require("ah.tools")`).
  The only use is `from_claude_code_name` (line 305) for OAuth tool name
  remapping. This makes the LLM abstraction layer depend on the tool layer,
  violating the foundation-has-zero-dependencies rule.

- **`init.tl` is three layers in one file.** It contains CLI argument parsing
  (lines 632-678), session management (lines 749-775), the agent loop
  (lines 203-487), prompt/skill/command expansion (lines 871-898), and
  display formatting (lines 181-200, 404-441). In the consensus architecture,
  the agent loop and session management belong in a middle layer, separate
  from the CLI entry point.

- **`db.tl` is clean.** It has no upward dependencies and provides a complete
  persistence interface. This is the strongest layer boundary in the codebase.

### Convergence path

1. Move `to_claude_code_name`/`from_claude_code_name` and the mapping tables
   (`CLAUDE_CODE_TOOLS`, `CLAUDE_CODE_TOOLS_REVERSE`) out of `tools.tl`.
   These belong in `api.tl` (they are an API-layer concern: normalizing
   wire-format tool names for OAuth) or in a shared `names.tl` module. This
   eliminates the `api.tl -> tools.tl` dependency.

2. Extract `run_agent` from `init.tl` into a `loop.tl` module. The function
   signature is already clean: `(d, system_prompt, model, prompt, parent_id)`.
   Pull the tool execution display logic and the SSE callback with it. The
   result is:

   ```
   api.tl    -> foundation: LLM streaming, retry, SSE parsing (zero deps)
   loop.tl   -> agent core: run_agent, tool dispatch, display
   db.tl     -> persistence (zero deps, consumed by loop.tl)
   tools.tl  -> tool definitions and registry (consumed by loop.tl)
   init.tl   -> application: CLI parsing, session selection, prompt expansion
   ```

3. Verify the dependency graph is acyclic: `init.tl -> loop.tl -> {api.tl, tools.tl, db.tl}`. No upward references.

---

## 2. Tool input validation

### Consensus pattern

Tool inputs are validated against their JSON schema *before* execution.
Pi-mono uses TypeBox + AJV. When validation fails, a structured error is
returned as `toolResult` with `isError: true`, giving the model a chance
to self-correct before any side effects occur.

### Current state

`ah` defines `input_schema` on every tool and sends it to the API for model
documentation. Individual tool `execute` functions check for required fields
manually (e.g. `tools.tl:67-69`: `if not file_path then return "error: path
is required", true`). But there is no centralized validation step. If the
model omits a field that a tool doesn't manually check, or sends the wrong
type, the tool hits a runtime error rather than a clean validation message.

The `execute_tool` function (`tools.tl:581-587`) dispatches directly:

```lua
local function execute_tool(name, input)
  local tool = get_tool(name)
  if not tool then
    return "error: unknown tool: " .. name, true
  end
  return tool.execute(input)
end
```

### Convergence path

Add a `validate_input(schema, input)` function that checks:
- All `required` fields are present.
- Field types match (`string`, `integer`, `object`, `array`, `boolean`).
- Return a structured error message listing all violations.

Call it in `execute_tool` between lookup and execution:

```lua
local function execute_tool(name, input)
  local tool = get_tool(name)
  if not tool then
    return "error: unknown tool: " .. name, true
  end
  local valid, err = validate_input(tool.input_schema, input)
  if not valid then
    return "error: invalid input: " .. err, true
  end
  return tool.execute(input)
end
```

This catches malformed inputs before any filesystem or process side effects.
Full JSON Schema validation is unnecessary — checking `required` and `type`
covers the common model errors.

---

## 3. Model-aware editing formats

### Consensus pattern

The editing tool format should match the model's training data. Attractor
specifies: OpenAI models get `apply_patch` in v4a format; Anthropic models
get `edit_file` with `old_string`/`new_string`; Gemini models use their
native format. Forcing cross-format usage degrades output quality.

### Current state

`ah` uses `old_string`/`new_string` exclusively (`tools.tl:174-226`).
The model list is Anthropic-only (`api.tl:18-22`): sonnet, opus, haiku.
Since the only supported models are Claude, the editing format matches
training data by default.

### Convergence path

No action needed while `ah` remains Claude-only. If multi-provider support
is added, implement provider-aware tool profiles:

1. Detect active provider from model name or config.
2. Swap the `edit` tool definition: `old_string`/`new_string` for Anthropic,
   `apply_patch` for OpenAI, etc.
3. The existing tool override mechanism (custom tools in `.ah/tools/`
   override builtins by name) already supports per-project format switching.

---

## 4. Context compaction

### Consensus pattern

Pi-mono triggers compaction at a configurable threshold (default 80% of
context window). The compaction prompt asks the model to preserve: what was
accomplished, work in progress, files involved, next steps, key constraints.
Full history is always preserved separately; compaction only affects what is
sent to the API. Attractor explicitly defers compaction to the host
application but provides context window awareness signals.

### Current state

`ah` has no compaction. Every message in the ancestry chain is sent to the
API on every turn (`init.tl:224-273`). There is no awareness of context
window limits and no summarization mechanism. Long sessions will hit context
limits and fail with an API error.

Token usage is tracked per-message in the database (`input_tokens`,
`output_tokens` in the `messages` table) but never consulted for compaction
decisions.

### Convergence path

Implement in stages:

1. **Context window awareness.** Define model context limits (e.g. sonnet =
   200k tokens). Before each API call, compare cumulative `input_tokens`
   from the most recent response against the model limit.

2. **Threshold trigger.** When `input_tokens / context_limit > 0.8`, trigger
   compaction before the next API call.

3. **Compaction prompt.** Send the full ancestry to the model with a
   compaction system prompt:

   ```
   Summarize this conversation for continuation. Preserve:
   - What was accomplished
   - Current work in progress
   - Files read, written, or edited
   - Pending next steps
   - Key constraints or decisions made
   ```

4. **Replace ancestry.** Create a new "compaction" message containing the
   summary. Set it as the root for subsequent API calls. The original
   messages remain in SQLite — compaction is a view-layer operation, not a
   data mutation.

5. **Extension point.** Allow the compaction prompt and threshold to be
   configured via `.ah/settings` or command-line flags.

The database already stores token counts per message. The ancestry CTE
already reconstructs the full chain. The main work is in the agent loop:
check threshold, call compaction, splice the result.

---

## 5. Structured event system

### Consensus pattern

Pi-mono emits structured events for everything: tool calls, tool results,
errors, state transitions. Events decouple the agent core from any specific
UI. Attractor requires events for all state transitions and defines a clean
event vocabulary.

### Current state

`ah` has an `events` table in the database (`db.tl:39-45`) and a
`log_event` function (`db.tl:396-414`). Currently only retry events are
logged (`init.tl:359-365`). Tool execution output goes directly to stderr
with inline formatting (`init.tl:404-441`). There is no event abstraction
between the agent loop and the display layer.

### Convergence path

1. **Define event types.** Create an enumeration of agent lifecycle events:

   ```
   agent_start, agent_end
   api_call_start, api_call_end
   tool_call_start, tool_call_end
   compaction_triggered, compaction_complete
   error, retry
   ```

2. **Add an event callback to the agent loop.** `run_agent` currently takes
   `(d, system_prompt, model, prompt, parent_id)`. Add an optional
   `on_event` callback parameter. The loop emits events through this
   callback instead of writing directly to stderr.

3. **Move display logic to the application layer.** The current stderr
   formatting in `init.tl:404-441` becomes one implementation of the event
   callback — the CLI display handler. Other handlers (JSON logging, RPC
   streaming, web UI) become possible without changing the loop.

4. **Persist events.** The `events` table and `log_event` function already
   exist. Extend them to cover all event types, not just retries.

---

## 6. Steering and followup queues

### Consensus pattern

Both pi-mono and attractor implement message injection between tool rounds.
Steering queues allow course correction during long tool chains ("stop
and try a different approach"). Followup queues allow messages to be
processed after the current input completes. This enables interactive
control without restarting the agent loop.

### Current state

The agent loop (`init.tl:276-487`) is a tight while loop: stream response,
persist, execute tools, repeat. The only interruption is `SIGINT`, which
sets the `interrupted` flag and exits the loop entirely. There is no way
to inject a message between tool rounds.

### Convergence path

1. **Add a message queue.** Before each API call in the loop, check a queue
   for pending messages. If present, append them to `api_messages` before
   calling `api.stream`.

2. **CLI input mechanism.** In a terminal context, check stdin for available
   input (non-blocking read) between tool rounds. If a line is available,
   add it to the steering queue.

3. **Signal-based injection.** Register a SIGUSR1 handler that reads from a
   side file (e.g. `.ah/steer`) and appends its contents to the queue. This
   enables injection from other processes.

4. **Followup queue.** After the agent loop completes (no more tool calls),
   check for queued followup messages. If present, start a new loop
   iteration with the followup as the next prompt.

---

## 7. Conversation branching UX

### Consensus pattern

Pi-mono offers `/tree` visualization, session navigation, and in-place
branching. Cxdb enables O(1) forking with speculative execution: branch,
try something, keep the branch that worked.

### Current state

`ah` supports branching via `@N` fork syntax and `scan` for listing the
current branch. The data model (parent_id in messages table, recursive CTE
ancestry) is correct and supports arbitrary tree structures.

The gap is in UX and programmatic use:

- No tree visualization across branches (only current branch via `scan`).
- No way to compare branches.
- No speculative execution (fork, try, evaluate, keep-or-discard).

### Convergence path

1. **Tree view command.** Add a `tree` command that shows all branches, not
   just the current one. The data is already in SQLite — query all messages
   and render the parent-child relationships.

2. **Branch comparison.** Add a `diff N M` command that shows divergence
   between two messages on different branches.

3. **Speculative execution.** This is an agent loop feature: fork the
   current context, run a prompt, evaluate the result, and either keep or
   discard the branch. The database already supports it; the missing piece
   is loop-level orchestration.

---

## 8. Split tool return values

### Consensus pattern

Pi-mono tools return split values: `output` (text for LLM consumption) and
`details` (structured data for UI rendering). This lets the agent loop feed
a concise summary to the model while the UI renders rich diffs, file trees,
or syntax-highlighted code blocks.

### Current state

`ah` tools return `(string, boolean)` — a single output string and an error
flag. The same string goes to both the model (as `tool_result` content) and
the UI (truncated to 3 lines on stderr, `init.tl:422-438`). There is no
structured data channel for the UI.

The image handling in `read` is a partial exception: it returns a JSON
envelope (`{"__image__": true, "content": [...]}`) that the agent loop
detects and unpacks (`init.tl:444-449`). But this is a special case, not a
general pattern.

### Convergence path

1. **Extend the Tool return type.** Change `execute` to return
   `(string, boolean, table|nil)` — output, is_error, details. The third
   return value is optional structured data for the UI.

2. **Populate details in builtin tools.** For example, `edit` could return
   `{path = "...", old_lines = 5, new_lines = 7}`. The `read` tool could
   return `{path = "...", line_count = 150}`. The `bash` tool could return
   `{command = "...", exit_code = 0, duration_ms = 1234}`.

3. **Use details in display.** The stderr output in the agent loop
   (`init.tl:404-441`) currently parses tool_name and tool_input to extract
   display parameters via `tool_key_param`. With structured details, this
   becomes a direct field access instead of re-parsing.

4. **Persist details.** Add a `details` column to `content_blocks` for tool
   result blocks. This supports richer offline review (e.g. `show` command).

---

## 9. Graceful abort and cleanup

### Consensus pattern

Attractor specifies a disciplined abort sequence: cancel in-flight LLM
streams, SIGTERM all running process groups, wait 2 seconds, SIGKILL
survivors, flush pending events, close subagents, transition session to
CLOSED.

### Current state

`ah` installs a SIGINT handler (`init.tl:901-903`) that sets a global
`interrupted` flag. The agent loop checks this flag at the top of each
iteration (`init.tl:276`). If set, the loop exits. There is no cleanup of
in-flight operations:

- An active `api.stream` call runs to completion even after interruption
  (the flag is only checked between iterations).
- The bash tool wraps commands in `timeout` but there is no mechanism to
  interrupt a running tool from outside the tool's process.
- No session state transition (IDLE/PROCESSING/CLOSED).

### Convergence path

1. **Thread interruption into streaming.** Pass an abort signal to
   `api.stream` that causes it to stop processing SSE events mid-stream.
   The response received so far can still be persisted (partial responses
   are valid).

2. **Tool-level abort.** Store the process handle from `child.spawn` and
   kill it on SIGINT. The bash tool creates a child process
   (`tools.tl:253`); if `interrupted` is set, send SIGTERM, wait 2s,
   send SIGKILL.

3. **Session state.** Add a `state` field to the `context` table:
   `idle`, `processing`, `closed`. Transition on agent start, completion,
   and interruption. This enables external tooling to query session status.

---

## 10. Output truncation for tool results

### Consensus pattern

Attractor defines per-tool output character limits via a `tool_output_limits`
map in the tool registry. Large outputs are truncated before being sent to
the model, preserving context window budget for more useful content.

### Current state

Tool outputs are sent to the model in full. The only truncation is in the
stderr display (3 lines, `init.tl:428`), which is cosmetic. If `read`
returns a 50,000-line file or `bash` produces megabytes of output, the
entire result goes into the API messages array.

### Convergence path

1. **Add a per-tool output limit.** Extend the `Tool` record with an
   optional `max_output_chars` field. Default to a reasonable global limit
   (e.g. 100,000 characters).

2. **Truncate in `execute_tool`.** After calling `tool.execute`, check
   output length against the limit. If exceeded, truncate and append a
   marker: `\n... (truncated, showing first N of M characters)`.

3. **Make limits configurable.** Allow overrides in `.ah/settings` or
   per-tool in custom tool definitions.

---

## 11. Cross-provider context handoff

### Consensus pattern

Pi-mono supports switching providers mid-session. When moving from Anthropic
to OpenAI, thinking traces are converted to `<thinking></thinking>` tagged
text blocks. The conversation history is normalized to the target provider's
format.

### Current state

`ah` is single-provider (Anthropic). The message format in the database
mirrors the Claude Messages API directly. There is no normalization layer
between stored messages and API requests.

### Convergence path

No action needed while `ah` remains Claude-only. If multi-provider support
is added:

1. **Normalize stored messages.** Define a provider-neutral message format
   in the database. Convert to provider-specific format when building API
   requests.

2. **Handle thinking blocks.** If switching from a model that returns
   thinking content to one that doesn't support it, convert thinking blocks
   to tagged text.

3. **Handle tool format differences.** Different providers expect tool calls
   and results in different formats. The conversion belongs in `api.tl`.

---

## 12. Configuration system

### Consensus pattern

Pi-mono follows strict precedence: CLI flags > project settings > global
settings > defaults. API keys have their own precedence chain. Custom models
are added via config file and hot-reload.

### Current state

`ah` has minimal configuration:
- Model selection via `-m` flag with hardcoded aliases (`api.tl:24-28`).
- Credentials via env vars and `.env` file (`auth.tl:27-46`).
- No settings file. No project-level or global config.
- No custom model registration.

### Convergence path

1. **Add a settings file.** Support `.ah/settings.json` (project) and
   `~/.ah/settings.json` (global). Precedence: CLI flags > project settings
   > global settings > defaults.

2. **Move model aliases to config.** Allow users to define custom model
   aliases in settings rather than hardcoding them in `api.tl`.

3. **Configurable defaults.** Settings file could specify default model,
   bash timeout, compaction threshold, output truncation limits.

---

## 13. Loop detection

### Consensus pattern

Attractor monitors for consecutive identical tool call patterns within a
configurable window (default 10). When detected, it injects a steering
message to redirect the model rather than letting it burn tokens in a loop.

### Current state

No loop detection. If the model repeatedly calls the same tool with the
same arguments, the loop continues until the context window fills or the
user interrupts with SIGINT.

### Convergence path

1. **Track recent tool calls.** Maintain a sliding window of recent
   `(tool_name, tool_input)` pairs in the agent loop.

2. **Detect repetition.** If the last N tool calls (e.g. 3-5) are identical,
   inject a steering message: "You appear to be repeating the same action.
   Consider a different approach."

3. **Configurable window.** Allow the detection window size and steering
   message to be configured.

---

## Priority matrix

Ranked by impact relative to effort:

| Priority | Area | Status | Effort | Impact |
|----------|------|--------|--------|--------|
| 1 | Context compaction (#4) | Missing | Medium | Critical — sessions die at context limits |
| 2 | Layer separation (#1) | Partial | Low | Structural — enables everything else |
| 3 | Tool input validation (#2) | Partial | Low | Eliminates a class of runtime errors |
| 4 | Output truncation (#10) | Missing | Low | Prevents context waste on large outputs |
| 5 | Loop detection (#13) | Missing | Low | Prevents token burn on stuck loops |
| 6 | Structured events (#5) | Partial | Medium | Decouples core from UI |
| 7 | Graceful abort (#9) | Partial | Medium | Better interrupt behavior |
| 8 | Steering queues (#6) | Missing | Medium | Interactive course correction |
| 9 | Split return values (#8) | Missing | Low | Better UI rendering |
| 10 | Branching UX (#7) | Partial | Medium | Speculative execution |
| 11 | Configuration (#12) | Minimal | Low | User customization |
| 12 | Model-aware editing (#3) | N/A | Low | Only if multi-provider |
| 13 | Cross-provider handoff (#11) | N/A | Medium | Only if multi-provider |
