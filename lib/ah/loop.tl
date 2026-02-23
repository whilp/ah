-- ah/loop.tl: agent loop (API call → tool dispatch → repeat)
local json = require("cosmic.json")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local auth = require("ah.auth")
local events = require("ah.events")
local queue = require("ah.queue")
local truncate = require("ah.truncate")
local compact = require("ah.compact")
local looputil = require("ah.looputil")
local looptool = require("ah.looptool")

-- Reference the global interrupted flag (set by application layer)
global interrupted: boolean

-- Loop detection thresholds
local LOOP_WARN_THRESHOLD = 3
local LOOP_BREAK_THRESHOLD = 5

-- Payload size threshold: warn when outgoing API payload exceeds this many bytes
local PAYLOAD_WARN_BYTES = 800000

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

-- Measure the byte size of the API messages payload by JSON-encoding it
local function measure_payload_bytes(api_messages: {any}): integer
  local encoded = json.encode(api_messages)
  return #encoded
end

-- Options for run_agent
local record AgentOpts
  max_tokens: integer
  max_turn_tokens: integer
  must_produce: string
end

-- Build API messages from ancestry chain, skipping incomplete messages
local function build_api_messages(d: db.DB, message_id: string, on_event: events.EventCallback): {any}
  local ancestry = db.get_ancestry(d, message_id)
  local api_messages: {any} = {}

  for _, msg in ipairs(ancestry) do
    local blocks = db.get_content_blocks(d, msg.id)
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
        table.insert(content, {type = "tool_use", id = block.tool_id, name = block.tool_name, input = input})
      elseif block.block_type == "tool_result" then
        local tool_output = block.tool_output as string
        local truncation = truncate.truncate_output(tool_output or "", block.tool_name as string or "")
        local api_content: any = truncation.content
        if tool_output and tool_output:sub(1, 14) == '{"__image__":' then
          local parsed = json.decode(tool_output) as {string: any}
          if parsed and parsed.__image__ and parsed.content then
            api_content = parsed.content
          end
        end
        table.insert(content, {type = "tool_result", tool_use_id = block.tool_id, content = api_content, is_error = block.is_error == 1})
      end
    end

    table.insert(api_messages, {role = msg.role, content = content})
    ::continue::
  end

  return api_messages
end

-- Repair dangling tool_use blocks in message history
local function repair_dangling_tool_use(api_messages: {any}, on_event: events.EventCallback)
  for i = 1, #api_messages - 1 do
    local msg = api_messages[i] as {string: any}
    if msg.role == "assistant" then
      local tool_use_ids: {string} = {}
      local msg_content = msg.content as {any}
      for _, block in ipairs(msg_content) do
        local b = block as {string: any}
        if b.type == "tool_use" then
          table.insert(tool_use_ids, b.id as string)
        end
      end

      if #tool_use_ids > 0 then
        local next_msg = api_messages[i + 1] as {string: any}
        local has_tool_results = false
        if next_msg.role == "user" then
          local next_content = next_msg.content as {any}
          for _, block in ipairs(next_content) do
            local b = block as {string: any}
            if b.type == "tool_result" then
              has_tool_results = true
              break
            end
          end
        end

        if not has_tool_results then
          local synthetic_results: {any} = {}
          for _, tid in ipairs(tool_use_ids) do
            table.insert(synthetic_results, {type = "tool_result", tool_use_id = tid, content = "error: tool execution was interrupted (session resumed)", is_error = true})
          end
          table.insert(api_messages, i + 1, {role = "user", content = synthetic_results})
          emit(on_event, events.error_event(string.format("repaired %d dangling tool_use block(s) in message history", #tool_use_ids)))
        end
      end
    end
  end
end

-- Send prompt and run agent loop
local function run_agent(d: db.DB, qdb: queue.QueueDB, system_prompt: string, model: string, prompt: string, parent_id: string, on_event: events.EventCallback, opts: AgentOpts): string
  opts = opts or {}
  local max_tokens = opts.max_tokens
  local must_produce = opts.must_produce
  local must_produce_reminded = false

  local creds, creds_err = auth.load_credentials()
  if not creds then
    emit(on_event, events.error_event("credentials: " .. creds_err))
    return "error"
  end

  transition_state(d, on_event, "processing")
  emit(on_event, events.agent_start(model, prompt, parent_id))

  db.begin_transaction(d)
  local user_msg = db.create_message(d, "user", parent_id)
  db.add_content_block(d, user_msg.id, "text", {content = prompt})
  db.commit(d)

  local api_messages = build_api_messages(d, user_msg.id, on_event)
  repair_dangling_tool_use(api_messages, on_event)

  local final_stop_reason = "unknown"
  local last_error: string = nil
  local turn_history: {string} = {}
  local last_input_tokens: integer = 0
  local cumulative_input_tokens: integer = 0
  local cumulative_output_tokens: integer = 0

  local function is_interrupted(): boolean
    return interrupted
  end

  while not interrupted do
    -- Drain steering queue
    if qdb then
      queue.update_heartbeat(qdb)
      local steering_msgs = queue.drain_steering(qdb)
      for _, steer_msg in ipairs(steering_msgs) do
        emit(on_event, events.steering_received(steer_msg.content, #steering_msgs))
        db.begin_transaction(d)
        local steer_user_msg = db.create_message(d, "user", user_msg.id)
        db.add_content_block(d, steer_user_msg.id, "text", {content = "[STEERING] " .. steer_msg.content})
        db.commit(d)
        table.insert(api_messages, {role = "user", content = {{type = "text", text = "[STEERING] " .. steer_msg.content}}})
        user_msg = steer_user_msg
      end
    end

    -- Compaction
    if last_input_tokens > 0 and compact.needs_compaction(last_input_tokens, model) then
      local context_limit = compact.get_context_limit(model)
      emit(on_event, events.compaction_triggered(last_input_tokens, context_limit))
      db.log_event(d, "compaction_triggered", nil, events.to_json(events.compaction_triggered(last_input_tokens, context_limit)))

      local compact_result, compact_err = compact.compact(api_messages, model, is_interrupted)
      if compact_result then
        db.begin_transaction(d)
        local compact_msg = db.create_message(d, "user", user_msg.id)
        db.add_content_block(d, compact_msg.id, "text", {content = "[COMPACTION SUMMARY]\n" .. compact_result.summary})
        db.commit(d)
        user_msg = compact_msg
        api_messages = {{role = "user", content = {{type = "text", text = compact_result.summary}}}}
        last_input_tokens = 0
        emit(on_event, events.compaction_complete(compact_result.input_tokens, compact_result.output_tokens))
        db.log_event(d, "compaction_complete", nil, events.to_json(events.compaction_complete(compact_result.input_tokens, compact_result.output_tokens)))
      else
        emit(on_event, events.error_event(compact_err))
        db.log_event(d, "error", nil, events.to_json(events.error_event(compact_err)))
        last_input_tokens = 0
      end
    end

    local payload_bytes = measure_payload_bytes(api_messages)
    if payload_bytes > PAYLOAD_WARN_BYTES then
      emit(on_event, events.payload_warn(payload_bytes, PAYLOAD_WARN_BYTES))
      db.log_event(d, "payload_warn", nil, events.to_json(events.payload_warn(payload_bytes, PAYLOAD_WARN_BYTES)))
    end
    emit(on_event, events.api_call_start(payload_bytes))

    -- Cache breakpoint
    local cache_msg_idx: integer = nil
    local cache_block_idx: integer = nil
    for i = #api_messages, 1, -1 do
      local msg = api_messages[i] as {string: any}
      local content = msg.content as {any}
      if content and #content > 0 then
        cache_msg_idx = i
        cache_block_idx = #content
        local block = content[cache_block_idx] as {string: any}
        block.cache_control = {type = "ephemeral"}
        break
      end
    end

    local response, err = api.stream(api_messages, {
        system = system_prompt, model = model, tools = tools.get_tool_definitions(),
        max_tokens = opts.max_turn_tokens,
      }, function(event: {string: any})
        if event.type == "content_block_delta" and event.delta then
          local delta = event.delta as {string: any}
          if delta.type == "text_delta" and delta.text then
            emit(on_event, events.text_delta(delta.text as string))
          end
        end
      end, is_interrupted)

    if cache_msg_idx and cache_block_idx then
      local msg = api_messages[cache_msg_idx] as {string: any}
      local content = msg.content as {any}
      local block = content[cache_block_idx] as {string: any}
      block.cache_control = nil
    end

    if err then
      emit(on_event, events.error_event(err))
      db.log_event(d, "error", nil, events.to_json(events.error_event(err)))
      last_error = err
      final_stop_reason = "error"
      break
    end

    if not response then
      emit(on_event, events.error_event("no response"))
      db.log_event(d, "error", nil, events.to_json(events.error_event("no response")))
      last_error = "no response"
      final_stop_reason = "error"
      break
    end

    local resp = response as {string: any}
    if interrupted or resp.stop_reason == "interrupted" then
      local resp_content = resp.content as {any}
      if resp_content and #resp_content > 0 then
        local abl: {{string: any}} = {}
        for _, block in ipairs(resp_content) do
          local b = block as {string: any}
          if b.type == "text" and b.text then
            table.insert(abl, {block_type = "text", content = b.text as string})
          end
        end
        if #abl > 0 then
          local u = (resp.usage or {}) as {string: any}
          db.begin_transaction(d)
          local partial_msg = db.create_message(d, "assistant", user_msg.id, {
              input_tokens = u.input_tokens as integer, output_tokens = u.output_tokens as integer,
              stop_reason = "interrupted", model = resp.model as string, api_latency_ms = resp.api_latency_ms as integer,
            })
          for _, blk in ipairs(abl) do
            db.add_content_block(d, partial_msg.id, "text", {content = blk.content as string})
          end
          db.commit(d)
        end
      end
      final_stop_reason = "interrupted"
      break
    end

    -- Collect response content blocks
    local resp_content = resp.content as {any}
    local assistant_api_content: {any} = {}
    local assistant_blocks: {{string: any}} = {}
    for _, block in ipairs(resp_content) do
      local b = block as {string: any}
      if b.type == "text" then
        table.insert(assistant_blocks, {block_type = "text", content = b.text as string})
        table.insert(assistant_api_content, {type = "text", text = b.text})
      elseif b.type == "tool_use" then
        local input_json = json.encode(b.input or {})
        table.insert(assistant_blocks, {block_type = "tool_use", tool_id = b.id as string, tool_name = b.name as string, tool_input = input_json})
        table.insert(assistant_api_content, {type = "tool_use", id = b.id, name = b.name, input = b.input or {}})
      end
    end

    local usage = (resp.usage or {}) as {string: any}
    local cache_creation_tokens = (usage.cache_creation_input_tokens or 0) as integer
    local cache_read_tokens = (usage.cache_read_input_tokens or 0) as integer
    local effective_input_tokens = ((usage.input_tokens or 0) as integer) + cache_creation_tokens + cache_read_tokens
    last_input_tokens = effective_input_tokens

    db.begin_transaction(d)
    local assistant_msg = db.create_message(d, "assistant", user_msg.id, {
        input_tokens = effective_input_tokens, output_tokens = usage.output_tokens as integer,
        stop_reason = resp.stop_reason as string, model = resp.model as string, api_latency_ms = resp.api_latency_ms as integer,
      })
    for _, blk in ipairs(assistant_blocks) do
      if blk.block_type == "text" then
        db.add_content_block(d, assistant_msg.id, "text", {content = blk.content as string})
      elseif blk.block_type == "tool_use" then
        db.add_content_block(d, assistant_msg.id, "tool_use", {tool_id = blk.tool_id as string, tool_name = blk.tool_name as string, tool_input = blk.tool_input as string})
      end
    end
    local retries = resp.retries as {{string: any}}
    if retries then
      for _, retry in ipairs(retries) do
        local retry_json = json.encode(retry)
        db.log_event(d, "retry", assistant_msg.id, retry_json)
        emit(on_event, events.retry_event((retry.attempt or 0) as integer, (retry.delay_ms or 0) as integer, (retry.status or 0) as integer, (retry.error or "") as string))
      end
    end
    db.commit(d)

    emit(on_event, events.api_call_end(assistant_msg.id, usage.input_tokens as integer, usage.output_tokens as integer, resp.api_latency_ms as integer, resp.model as string, cache_creation_tokens, cache_read_tokens))
    db.log_event(d, "api_call_end", assistant_msg.id, events.to_json(events.api_call_end(assistant_msg.id, usage.input_tokens as integer, usage.output_tokens as integer, resp.api_latency_ms as integer, resp.model as string, cache_creation_tokens, cache_read_tokens)))

    cumulative_input_tokens = effective_input_tokens
    cumulative_output_tokens = cumulative_output_tokens + ((usage.output_tokens or 0) as integer)

    if max_tokens and (cumulative_input_tokens + cumulative_output_tokens) > max_tokens then
      emit(on_event, events.budget_exceeded(cumulative_input_tokens, cumulative_output_tokens, max_tokens))
      db.log_event(d, "budget_exceeded", assistant_msg.id, events.to_json(events.budget_exceeded(cumulative_input_tokens, cumulative_output_tokens, max_tokens)))
      local pending_tool_ids: {string} = {}
      for _, blk in ipairs(assistant_blocks) do
        if blk.block_type == "tool_use" then table.insert(pending_tool_ids, blk.tool_id as string) end
      end
      if #pending_tool_ids > 0 then
        db.begin_transaction(d)
        local stub_msg = db.create_message(d, "user", assistant_msg.id)
        for _, tid in ipairs(pending_tool_ids) do
          db.add_content_block(d, stub_msg.id, "tool_result", {tool_id = tid, tool_output = "error: tool execution skipped (token budget exceeded)", is_error = true, duration_ms = 0})
        end
        db.commit(d)
      end
      final_stop_reason = "budget_exceeded"
      break
    end

    table.insert(api_messages, {role = "assistant", content = assistant_api_content})

    local tool_calls = api.extract_tool_calls(response) as {any}
    if #tool_calls == 0 then
      if qdb then
        local followup_msgs = queue.drain_followup(qdb)
        if #followup_msgs > 0 then
          for _, followup_msg in ipairs(followup_msgs) do
            emit(on_event, events.followup_received(followup_msg.content, #followup_msgs))
            db.begin_transaction(d)
            local followup_user_msg = db.create_message(d, "user", assistant_msg.id)
            db.add_content_block(d, followup_user_msg.id, "text", {content = followup_msg.content})
            db.commit(d)
            table.insert(api_messages, {role = "user", content = {{type = "text", text = followup_msg.content}}})
            user_msg = followup_user_msg
          end
          goto continue_loop
        end
      end

      if must_produce and not must_produce_reminded then
        local f = io.open(must_produce, "r")
        if f then f:close()
        else
          must_produce_reminded = true
          local reminder = "You must write the file `" .. must_produce .. "` before finishing. Please produce it now."
          db.begin_transaction(d)
          local reminder_msg = db.create_message(d, "user", assistant_msg.id)
          db.add_content_block(d, reminder_msg.id, "text", {content = reminder})
          db.commit(d)
          table.insert(api_messages, {role = "user", content = {{type = "text", text = reminder}}})
          user_msg = reminder_msg
          goto continue_loop
        end
      end

      final_stop_reason = resp.stop_reason as string or "end_turn"
      break
    end

    -- Execute tool calls
    local exec_result = looptool.execute_tool_calls(tool_calls, (resp.think_time or 0) as number, assistant_msg.id, d, on_event)
    local new_user_msg = looptool.persist_tool_results(d, assistant_msg.id, exec_result, api_messages)
    if new_user_msg then user_msg = new_user_msg end

    if exec_result.was_interrupted then
      final_stop_reason = "interrupted"
      break
    end

    -- Loop detection
    local sig = looputil.turn_signature(tool_calls)
    table.insert(turn_history, sig)
    local max_history = LOOP_BREAK_THRESHOLD * 2
    if #turn_history > max_history then
      local trimmed: {string} = {}
      for i = #turn_history - max_history + 1, #turn_history do
        table.insert(trimmed, turn_history[i])
      end
      turn_history = trimmed
    end

    local consecutive = looputil.check_loop(turn_history)
    if consecutive >= LOOP_BREAK_THRESHOLD then
      emit(on_event, events.loop_detected(consecutive, sig, "break"))
      db.log_event(d, "loop_detected", assistant_msg.id, events.to_json(events.loop_detected(consecutive, sig, "break")))
      final_stop_reason = "loop_detected"
      break
    elseif consecutive >= LOOP_WARN_THRESHOLD then
      emit(on_event, events.loop_detected(consecutive, sig, "warn"))
      db.log_event(d, "loop_detected", assistant_msg.id, events.to_json(events.loop_detected(consecutive, sig, "warn")))
      local steering_text = string.format("[LOOP DETECTED] You have repeated the same tool call pattern %d times (%s). This indicates you may be stuck in a loop. Try a different approach or ask the user for help.", consecutive, sig)
      db.begin_transaction(d)
      local loop_steer_msg = db.create_message(d, "user", user_msg.id)
      db.add_content_block(d, loop_steer_msg.id, "text", {content = steering_text})
      db.commit(d)
      table.insert(api_messages, {role = "user", content = {{type = "text", text = steering_text}}})
      user_msg = loop_steer_msg
    end

    final_stop_reason = "tool_use"
    ::continue_loop::
  end

  if interrupted then
    tools.abort_running_tools()
    final_stop_reason = "interrupted"
  end

  transition_state(d, on_event, "idle")
  local totals = db.get_session_token_totals(d)
  emit(on_event, events.agent_end(final_stop_reason, totals.input_tokens, totals.output_tokens, last_error, totals.cache_read_tokens))
  db.log_event(d, "agent_end", nil, events.to_json(events.agent_end(final_stop_reason, totals.input_tokens, totals.output_tokens, last_error, totals.cache_read_tokens)))

  if must_produce then
    local f = io.open(must_produce, "r")
    if f then f:close()
    else
      emit(on_event, events.error_event("must_produce: " .. must_produce .. " not created"))
      return "error"
    end
  end

  return final_stop_reason
end

return {
  run_agent = run_agent,
  AgentOpts = AgentOpts,
  tool_key_param = looputil.tool_key_param,
  wrap_command = looputil.wrap_command,
  shorten_path = looputil.shorten_path,
  turn_signature = looputil.turn_signature,
  check_loop = looputil.check_loop,
  LOOP_WARN_THRESHOLD = LOOP_WARN_THRESHOLD,
  LOOP_BREAK_THRESHOLD = LOOP_BREAK_THRESHOLD,
  measure_payload_bytes = measure_payload_bytes,
  PAYLOAD_WARN_BYTES = PAYLOAD_WARN_BYTES,
}
