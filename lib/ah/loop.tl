-- ah/loop.tl: agent loop (tool dispatch, event emission)
local json = require("cosmic.json")
local unix = require("cosmo.unix")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local auth = require("ah.auth")
local events = require("ah.events")
local queue = require("ah.queue")
local truncate = require("ah.truncate")
local compact = require("ah.compact")

-- Reference the global interrupted flag (set by application layer)
global interrupted: boolean

-- Loop detection thresholds
local LOOP_WARN_THRESHOLD = 3   -- Consecutive identical turns before steering injection
local LOOP_BREAK_THRESHOLD = 5  -- Consecutive identical turns before forced break

-- Get monotonic time in seconds
local function now(): number
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return s + ns / 1e9
end

-- Extract key parameter from tool details or input for display
local function tool_key_param(tool_name: string, tool_input: string, details_json: string): string
  -- Try details first (structured data from tool execution)
  if details_json then
    local details = json.decode(details_json) as {string:any}
    if details then
      if details.path then
        if tool_name == "edit" then
          -- For edit, include line change info from details
          local suffix = ""
          if details.old_lines and details.new_lines then
            suffix = string.format(" (%d → %d lines)", details.old_lines as integer, details.new_lines as integer)
          end
          return (details.path as string) .. suffix
        end
        return details.path as string
      elseif details.command then
        local cmd = details.command as string
        if #cmd > 80 then
          return cmd:sub(1, 77) .. "..."
        end
        return cmd
      end
    end
  end

  -- Fall back to parsing tool_input JSON
  if not tool_input then return "" end
  local input = json.decode(tool_input) as {string:any}
  if not input then return "" end

  if tool_name == "read" or tool_name == "write" then
    return (input.path or "") as string
  elseif tool_name == "edit" then
    return string.format("%s: %s → %s", input.path or "",
      ((input.old_string or "") as string):sub(1, 20),
      ((input.new_string or "") as string):sub(1, 20))
  elseif tool_name == "bash" then
    local cmd = (input.command or "") as string
    if #cmd > 80 then
      return cmd:sub(1, 77) .. "..."
    end
    return cmd
  end
  return ""
end

-- Compute a turn signature from a list of tool calls.
-- The signature captures the tool names and key parameters to identify
-- repetitive patterns across turns. For edit operations, includes the full
-- old_string and new_string to distinguish edits to the same file.
local function turn_signature(tool_calls: {any}): string
  local parts: {string} = {}
  for _, tool_call in ipairs(tool_calls) do
    local tc = tool_call as {string:any}
    local input = (tc.input or {}) as {string:any}
    local input_json = json.encode(input)
    local key = tool_key_param(tc.name as string, input_json, nil)
    -- For edit tool, append old_string and new_string to avoid collisions
    -- when multiple edits target the same file with different content.
    if tc.name == "edit" and input then
      local old_s = (input.old_string or "") as string
      local new_s = (input.new_string or "") as string
      key = key .. "|" .. old_s .. "|" .. new_s
    end
    table.insert(parts, (tc.name as string) .. ":" .. key)
  end
  return table.concat(parts, "|")
end

-- Check for consecutive identical signatures at the end of the history.
-- Returns the count of consecutive identical entries (1 = no repetition).
local function check_loop(history: {string}): integer
  if #history < 2 then return #history end
  local current = history[#history]
  local count = 1
  for i = #history - 1, 1, -1 do
    if history[i] == current then
      count = count + 1
    else
      break
    end
  end
  return count
end

-- Emit an event through the callback, silently ignoring if no callback
local function emit(on_event: events.EventCallback, event: events.EventData)
  if on_event then
    on_event(event)
  end
end

-- Transition session state and emit event
local function transition_state(d: db.DB, on_event: events.EventCallback, to_state: string)
  local from_state = db.get_session_state(d)
  if from_state ~= to_state then
    db.set_session_state(d, to_state)
    emit(on_event, events.state_change(from_state, to_state))
    db.log_event(d, "state_change", nil, events.to_json(events.state_change(from_state, to_state)))
  end
end

-- Options for run_agent
local record AgentOpts
  max_tokens: integer  -- Optional token budget (input + output combined). Stop with budget_exceeded when exceeded.
end

-- Send prompt and run agent loop
-- qdb: optional queue database for inter-process coordination (steering/followup)
-- on_event: optional callback for structured lifecycle events.
-- When provided, the loop emits events instead of writing directly to stderr/stdout.
-- When nil, the loop still functions but produces no output.
-- opts: optional agent options (e.g. token budget)
local function run_agent(d: db.DB, qdb: queue.QueueDB, system_prompt: string, model: string, prompt: string, parent_id: string, on_event: events.EventCallback, opts: AgentOpts)
  opts = opts or {}
  local max_tokens = opts.max_tokens

  -- Load credentials to determine if OAuth mode
  local creds, creds_err = auth.load_credentials()
  if not creds then
    emit(on_event, events.error_event("credentials: " .. creds_err))
    return
  end
  local is_oauth = creds.is_oauth or false

  -- Transition to processing state
  transition_state(d, on_event, "processing")

  -- Emit agent_start event
  emit(on_event, events.agent_start(model, prompt, parent_id))

  -- Create user message (atomic: message + content block)
  db.begin_transaction(d)
  local user_msg = db.create_message(d, "user", parent_id)
  db.add_content_block(d, user_msg.id, "text", {content = prompt})
  db.commit(d)

  -- Build messages from ancestry (skip incomplete messages from crashes)
  local ancestry = db.get_ancestry(d, user_msg.id)
  local api_messages: {any} = {}

  for _, msg in ipairs(ancestry) do
    local blocks = db.get_content_blocks(d, msg.id)

    -- Skip messages with no content blocks (incomplete from crash)
    if #blocks == 0 then
      emit(on_event, events.error_event(string.format("skipping incomplete message %s (no content blocks)", msg.id)))
      goto continue
    end

    local content: {any} = {}

    for _, block in ipairs(blocks) do
      if block.block_type == "text" then
        table.insert(content, {type = "text", text = block.content})
      elseif block.block_type == "tool_use" then
        local input = block.tool_input and json.decode(block.tool_input as string) or {}
        table.insert(content, {
          type = "tool_use",
          id = block.tool_id,
          name = block.tool_name,
          input = input,
        })
      elseif block.block_type == "tool_result" then
        -- Truncate stored output for API (full output preserved in DB)
        local tool_output = block.tool_output as string
        local truncation = truncate.truncate_output(tool_output or "", block.tool_name as string or "")
        local api_content: any = truncation.content
        -- Check if result is structured (image content)
        if tool_output and tool_output:sub(1, 14) == '{"__image__":' then
          local parsed = json.decode(tool_output) as {string:any}
          if parsed and parsed.__image__ and parsed.content then
            api_content = parsed.content
          end
        end
        table.insert(content, {
          type = "tool_result",
          tool_use_id = block.tool_id,
          content = api_content,
          is_error = block.is_error == 1,
        })
      end
    end

    table.insert(api_messages, {
      role = msg.role,
      content = content,
    })
    ::continue::
  end

  -- Track final stop reason for agent_end event
  local final_stop_reason = "unknown"

  -- Turn signature history for loop detection
  local turn_history: {string} = {}

  -- Track input tokens from last API response for compaction decisions
  local last_input_tokens: integer = 0

  -- Track cumulative tokens for budget enforcement
  local cumulative_input_tokens: integer = 0
  local cumulative_output_tokens: integer = 0

  -- Closure for api.stream to check interruption mid-stream
  local function is_interrupted(): boolean
    return interrupted
  end

  -- Agent loop
  while not interrupted do
    -- Update heartbeat and drain steering queue before API call
    if qdb then
      queue.update_heartbeat(qdb)

      local steering_msgs = queue.drain_steering(qdb)
      for _, steer_msg in ipairs(steering_msgs) do
        emit(on_event, events.steering_received(steer_msg.content, #steering_msgs))

        -- Create steering user message and add to conversation
        db.begin_transaction(d)
        local steer_user_msg = db.create_message(d, "user", user_msg.id)
        db.add_content_block(d, steer_user_msg.id, "text", {content = "[STEERING] " .. steer_msg.content})
        db.commit(d)

        -- Add to API messages
        table.insert(api_messages, {
          role = "user",
          content = {{type = "text", text = "[STEERING] " .. steer_msg.content}},
        })

        -- Update parent for next iteration
        user_msg = steer_user_msg
      end
    end

    -- Check if compaction is needed before API call
    if last_input_tokens > 0 and compact.needs_compaction(last_input_tokens, model) then
      local context_limit = compact.get_context_limit(model)
      emit(on_event, events.compaction_triggered(last_input_tokens, context_limit))
      db.log_event(d, "compaction_triggered", nil, events.to_json(events.compaction_triggered(last_input_tokens, context_limit)))

      local compact_result, compact_err = compact.compact(api_messages, model, is_interrupted)
      if compact_result then
        -- Persist compaction summary as a user message so it survives crashes.
        -- The full conversation is always preserved; this message acts as the
        -- compaction checkpoint that a new invocation can rebuild from.
        db.begin_transaction(d)
        local compact_msg = db.create_message(d, "user", user_msg.id)
        db.add_content_block(d, compact_msg.id, "text", {content = "[COMPACTION SUMMARY]\n" .. compact_result.summary})
        db.commit(d)
        user_msg = compact_msg

        -- Replace api_messages with compacted summary
        api_messages = {{
          role = "user",
          content = {{type = "text", text = compact_result.summary}},
        }}
        last_input_tokens = 0  -- Reset to avoid re-triggering

        emit(on_event, events.compaction_complete(compact_result.input_tokens, compact_result.output_tokens))
        db.log_event(d, "compaction_complete", nil, events.to_json(events.compaction_complete(compact_result.input_tokens, compact_result.output_tokens)))
      else
        -- Compaction failed - continue without it
        emit(on_event, events.error_event(compact_err))
        last_input_tokens = 0  -- Don't keep retrying
      end
    end

    -- Emit api_call_start
    emit(on_event, events.api_call_start())

    -- Add cache_control breakpoint on the last content block of the last message.
    -- This tells the Anthropic API to cache everything up to this point,
    -- reducing input token costs on subsequent turns.
    local cache_msg_idx: integer = nil
    local cache_block_idx: integer = nil
    for i = #api_messages, 1, -1 do
      local msg = api_messages[i] as {string:any}
      local content = msg.content as {any}
      if content and #content > 0 then
        cache_msg_idx = i
        cache_block_idx = #content
        local block = content[cache_block_idx] as {string:any}
        block.cache_control = {type = "ephemeral"}
        break
      end
    end

    -- Stream response with mid-stream interruption support
    local response, err = api.stream(api_messages, {
      system = system_prompt,
      model = model,
      tools = tools.get_tool_definitions(),
    }, function(event: {string:any})
      if event.type == "content_block_delta" and event.delta then
        local delta = event.delta as {string:any}
        if delta.type == "text_delta" and delta.text then
          emit(on_event, events.text_delta(delta.text as string))
        end
      end
    end, is_interrupted)

    -- Remove the cache_control marker we added (clean up for next iteration)
    if cache_msg_idx and cache_block_idx then
      local msg = api_messages[cache_msg_idx] as {string:any}
      local content = msg.content as {any}
      local block = content[cache_block_idx] as {string:any}
      block.cache_control = nil
    end

    if err then
      emit(on_event, events.error_event(err))
      final_stop_reason = "error"
      break
    end

    if not response then
      emit(on_event, events.error_event("no response"))
      final_stop_reason = "error"
      break
    end

    -- Check if stream was interrupted - persist partial response and exit
    local resp = response as {string:any}
    if interrupted or resp.stop_reason == "interrupted" then
      -- Persist partial assistant response if we have any content
      local resp_content = resp.content as {any}
      if resp_content and #resp_content > 0 then
        local assistant_blocks: {{string:any}} = {}
        for _, block in ipairs(resp_content) do
          local b = block as {string:any}
          if b.type == "text" and b.text then
            table.insert(assistant_blocks, {block_type = "text", content = b.text as string})
          end
        end
        if #assistant_blocks > 0 then
          local usage = (resp.usage or {}) as {string:any}
          db.begin_transaction(d)
          local partial_msg = db.create_message(d, "assistant", user_msg.id, {
            input_tokens = usage.input_tokens as integer,
            output_tokens = usage.output_tokens as integer,
            stop_reason = "interrupted",
            model = resp.model as string,
            api_latency_ms = resp.api_latency_ms as integer,
          })
          for _, blk in ipairs(assistant_blocks) do
            db.add_content_block(d, partial_msg.id, "text", {content = blk.content as string})
          end
          db.commit(d)
        end
      end
      final_stop_reason = "interrupted"
      break
    end

    -- Collect response content blocks before writing to DB
    local resp_content = resp.content as {any}
    local assistant_api_content: {any} = {}
    local assistant_blocks: {{string:any}} = {}

    for _, block in ipairs(resp_content) do
      local b = block as {string:any}
      if b.type == "text" then
        table.insert(assistant_blocks, {block_type = "text", content = b.text as string})
        table.insert(assistant_api_content, {type = "text", text = b.text})
      elseif b.type == "tool_use" then
        local input_json = json.encode(b.input or {})
        table.insert(assistant_blocks, {
          block_type = "tool_use",
          tool_id = b.id as string,
          tool_name = b.name as string,
          tool_input = input_json,
        })
        table.insert(assistant_api_content, {
          type = "tool_use",
          id = b.id,
          name = b.name,
          input = b.input or {},
        })
      end
    end

    -- Extract usage and metadata from response
    local usage = (resp.usage or {}) as {string:any}
    last_input_tokens = (usage.input_tokens or 0) as integer
    local cache_creation_tokens = (usage.cache_creation_input_tokens or 0) as integer
    local cache_read_tokens = (usage.cache_read_input_tokens or 0) as integer
    local msg_opts: db.MessageOpts = {
      input_tokens = usage.input_tokens as integer,
      output_tokens = usage.output_tokens as integer,
      stop_reason = resp.stop_reason as string,
      model = resp.model as string,
      api_latency_ms = resp.api_latency_ms as integer,
    }

    -- Atomically write assistant message + all content blocks
    db.begin_transaction(d)
    local assistant_msg = db.create_message(d, "assistant", user_msg.id, msg_opts)
    for _, blk in ipairs(assistant_blocks) do
      if blk.block_type == "text" then
        db.add_content_block(d, assistant_msg.id, "text", {content = blk.content as string})
      elseif blk.block_type == "tool_use" then
        db.add_content_block(d, assistant_msg.id, "tool_use", {
          tool_id = blk.tool_id as string,
          tool_name = blk.tool_name as string,
          tool_input = blk.tool_input as string,
        })
      end
    end

    -- Log retry events if any occurred
    local retries = resp.retries as {{string:any}}
    if retries then
      for _, retry in ipairs(retries) do
        local retry_json = json.encode(retry)
        db.log_event(d, "retry", assistant_msg.id, retry_json)
        emit(on_event, events.retry_event(
          (retry.attempt or 0) as integer,
          (retry.delay_ms or 0) as integer,
          (retry.status or 0) as integer,
          (retry.error or "") as string
        ))
      end
    end

    db.commit(d)

    -- Emit api_call_end with message metadata and cache stats
    emit(on_event, events.api_call_end(
      assistant_msg.id,
      usage.input_tokens as integer,
      usage.output_tokens as integer,
      resp.api_latency_ms as integer,
      resp.model as string,
      cache_creation_tokens,
      cache_read_tokens
    ))

    -- Log api_call_end event to DB
    db.log_event(d, "api_call_end", assistant_msg.id, events.to_json(events.api_call_end(
      assistant_msg.id,
      usage.input_tokens as integer,
      usage.output_tokens as integer,
      resp.api_latency_ms as integer,
      resp.model as string,
      cache_creation_tokens,
      cache_read_tokens
    )))

    -- Accumulate tokens for budget tracking
    cumulative_input_tokens = cumulative_input_tokens + ((usage.input_tokens or 0) as integer)
    cumulative_output_tokens = cumulative_output_tokens + ((usage.output_tokens or 0) as integer)

    -- Check token budget
    if max_tokens and (cumulative_input_tokens + cumulative_output_tokens) > max_tokens then
      emit(on_event, events.budget_exceeded(cumulative_input_tokens, cumulative_output_tokens, max_tokens))
      db.log_event(d, "budget_exceeded", assistant_msg.id,
        events.to_json(events.budget_exceeded(cumulative_input_tokens, cumulative_output_tokens, max_tokens)))
      final_stop_reason = "budget_exceeded"
      break
    end

    -- Add assistant message to API messages
    table.insert(api_messages, {role = "assistant", content = assistant_api_content})

    -- Check for tool calls
    local tool_calls = api.extract_tool_calls(response) as {any}
    if #tool_calls == 0 then
      -- No tool calls - check for followup messages before exiting
      if qdb then
        local followup_msgs = queue.drain_followup(qdb)
        if #followup_msgs > 0 then
          -- Process followup messages by injecting them as new user messages
          for _, followup_msg in ipairs(followup_msgs) do
            emit(on_event, events.followup_received(followup_msg.content, #followup_msgs))

            -- Create followup user message
            db.begin_transaction(d)
            local followup_user_msg = db.create_message(d, "user", assistant_msg.id)
            db.add_content_block(d, followup_user_msg.id, "text", {content = followup_msg.content})
            db.commit(d)

            -- Add to API messages
            table.insert(api_messages, {
              role = "user",
              content = {{type = "text", text = followup_msg.content}},
            })

            -- Update user_msg for next iteration
            user_msg = followup_user_msg
          end
          -- Continue the loop with followup messages
          goto continue_loop
        end
      end

      final_stop_reason = resp.stop_reason as string or "end_turn"
      break  -- Done, no tool calls and no followup
    end

    -- Execute tool calls and collect results before writing to DB
    local tool_results_content: {any} = {}
    local tool_result_blocks: {{string:any}} = {}
    local think_time = (resp.think_time or 0) as number
    local tool_count = #tool_calls

    for i, tool_call in ipairs(tool_calls) do
      -- Check for interruption between tool calls
      if interrupted then
        -- Abort any running tool processes
        tools.abort_running_tools()
        final_stop_reason = "interrupted"
        break
      end

      local tc = tool_call as {string:any}
      local input_json = json.encode(tc.input or {})

      -- Compute preliminary key from input for tool_call_start event
      local key = tool_key_param(tc.name as string, input_json, nil)

      -- Emit tool_call_start
      emit(on_event, events.tool_call_start(tc.name as string, input_json, key, i, tool_count))

      local start = now()
      local result, is_error, details = tools.execute_tool(tc.name as string, (tc.input or {}) as {string:any})
      local elapsed = now() - start

      -- If interrupted during tool execution, abort remaining tools
      if interrupted then
        tools.abort_running_tools()
        -- Still record this tool's result (it completed or was killed)
        local elapsed_ms = math.floor(elapsed * 1000) as integer
        emit(on_event, events.tool_call_end(tc.name as string, result, is_error, elapsed_ms, key, i, tool_count))
        db.log_event(d, "tool_call_end", assistant_msg.id, events.to_json(events.tool_call_end(tc.name as string, "", is_error, elapsed_ms, key, i, tool_count)))

        -- Encode details for interrupted tool result
        local int_details_json: string = nil
        if details then
          int_details_json = json.encode(details as {string:any})
        end

        table.insert(tool_result_blocks, {
          tool_id = tc.id as string,
          tool_output = result,
          is_error = is_error,
          duration_ms = elapsed_ms,
          details = int_details_json,
        })
        table.insert(tool_results_content, {
          type = "tool_result",
          tool_use_id = tc.id,
          content = result,
          is_error = is_error,
        })
        final_stop_reason = "interrupted"
        break
      end

      -- First tool includes think time in its timing
      if i == 1 then
        elapsed = elapsed + think_time
      end

      local elapsed_ms = math.floor(elapsed * 1000) as integer

      -- Encode details for display and persistence
      local details_json: string = nil
      if details then
        details_json = json.encode(details as {string:any})
      end

      -- Recompute key with details for richer display in tool_call_end
      key = tool_key_param(tc.name as string, input_json, details_json)

      -- Emit tool_call_end with full (non-truncated) output
      emit(on_event, events.tool_call_end(tc.name as string, result, is_error, elapsed_ms, key, i, tool_count))

      -- Log tool_call_end event to DB (without output to avoid bloat)
      db.log_event(d, "tool_call_end", assistant_msg.id, events.to_json(events.tool_call_end(tc.name as string, "", is_error, elapsed_ms, key, i, tool_count)))

      -- Truncate output for the API (full output preserved in DB and events)
      local truncation = truncate.truncate_output(result, tc.name as string)
      local api_result = truncation.content

      -- Check if result is structured (image content) — skip truncation for images
      local api_content: any = api_result
      if result:sub(1, 14) == '{"__image__":' then
        local parsed = json.decode(result) as {string:any}
        if parsed and parsed.__image__ and parsed.content then
          api_content = parsed.content
        end
      end

      -- Collect for later atomic write (store full output in DB)
      table.insert(tool_result_blocks, {
        tool_id = tc.id as string,
        tool_output = result,
        is_error = is_error,
        duration_ms = elapsed_ms,
        details = details_json,
      })

      -- Add to API messages content (truncated output)
      table.insert(tool_results_content, {
        type = "tool_result",
        tool_use_id = tc.id,
        content = api_content,
        is_error = is_error,
      })
    end

    -- Write tool results if we have any (even partial results from interruption)
    if #tool_result_blocks > 0 then
      -- Atomically write tool result message + all content blocks
      db.begin_transaction(d)
      local tool_result_msg = db.create_message(d, "user", assistant_msg.id)
      for _, blk in ipairs(tool_result_blocks) do
        db.add_content_block(d, tool_result_msg.id, "tool_result", {
          tool_id = blk.tool_id as string,
          tool_output = blk.tool_output as string,
          is_error = blk.is_error as boolean,
          duration_ms = blk.duration_ms as integer,
          details = blk.details as string,
        })
      end
      db.commit(d)

      -- Add the tool results as a user message to API messages
      table.insert(api_messages, {role = "user", content = tool_results_content})

      -- Update user_msg for next iteration parent
      user_msg = tool_result_msg
    end

    -- Exit if interrupted during tool execution
    if interrupted then
      break
    end

    -- Loop detection: check for repetitive tool call patterns
    local sig = turn_signature(tool_calls)
    table.insert(turn_history, sig)

    -- Cap turn history to avoid unbounded growth. Only the most recent
    -- entries matter for loop detection; older entries are never examined.
    local max_history = LOOP_BREAK_THRESHOLD * 2
    if #turn_history > max_history then
      local trimmed: {string} = {}
      for i = #turn_history - max_history + 1, #turn_history do
        table.insert(trimmed, turn_history[i])
      end
      turn_history = trimmed
    end

    local consecutive = check_loop(turn_history)

    if consecutive >= LOOP_BREAK_THRESHOLD then
      -- Too many identical turns even after steering - force break
      emit(on_event, events.loop_detected(consecutive, sig, "break"))
      db.log_event(d, "loop_detected", assistant_msg.id,
        events.to_json(events.loop_detected(consecutive, sig, "break")))
      final_stop_reason = "loop_detected"
      break
    elseif consecutive >= LOOP_WARN_THRESHOLD then
      -- Inject steering to break the loop
      emit(on_event, events.loop_detected(consecutive, sig, "warn"))
      db.log_event(d, "loop_detected", assistant_msg.id,
        events.to_json(events.loop_detected(consecutive, sig, "warn")))

      local steering_text = string.format(
        "[LOOP DETECTED] You have repeated the same tool call pattern %d times (%s). " ..
        "This indicates you may be stuck in a loop. Try a different approach or " ..
        "ask the user for help.",
        consecutive, sig)

      -- Create steering user message
      db.begin_transaction(d)
      local loop_steer_msg = db.create_message(d, "user", user_msg.id)
      db.add_content_block(d, loop_steer_msg.id, "text", {content = steering_text})
      db.commit(d)

      -- Add to API messages
      table.insert(api_messages, {
        role = "user",
        content = {{type = "text", text = steering_text}},
      })

      user_msg = loop_steer_msg
    end

    final_stop_reason = "tool_use"

    ::continue_loop::
  end

  if interrupted then
    -- Final cleanup: abort any straggler processes
    tools.abort_running_tools()
    final_stop_reason = "interrupted"
  end

  -- Transition to idle (or closed if interrupted)
  transition_state(d, on_event, "idle")

  -- Query final token totals from DB (includes all messages in session, not just this run)
  local totals = db.get_session_token_totals(d)

  -- Emit agent_end with token totals
  emit(on_event, events.agent_end(final_stop_reason, totals.input_tokens, totals.output_tokens))

  -- Log agent_end event to DB
  db.log_event(d, "agent_end", nil, events.to_json(events.agent_end(final_stop_reason, totals.input_tokens, totals.output_tokens)))
end

return {
  run_agent = run_agent,
  AgentOpts = AgentOpts,
  tool_key_param = tool_key_param,
  turn_signature = turn_signature,
  check_loop = check_loop,
  LOOP_WARN_THRESHOLD = LOOP_WARN_THRESHOLD,
  LOOP_BREAK_THRESHOLD = LOOP_BREAK_THRESHOLD,
}
