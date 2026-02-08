-- ah/loop.tl: agent loop (tool dispatch, event emission)
local json = require("cosmic.json")
local unix = require("cosmo.unix")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local auth = require("ah.auth")
local events = require("ah.events")

-- Reference the global interrupted flag (set by application layer)
global interrupted: boolean

-- Get monotonic time in seconds
local function now(): number
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return s + ns / 1e9
end

-- Extract key parameter from tool input for display
local function tool_key_param(tool_name: string, tool_input: string): string
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

-- Emit an event through the callback, silently ignoring if no callback
local function emit(on_event: events.EventCallback, event: events.EventData)
  if on_event then
    on_event(event)
  end
end

-- Send prompt and run agent loop
-- on_event: optional callback for structured lifecycle events.
-- When provided, the loop emits events instead of writing directly to stderr/stdout.
-- When nil, the loop still functions but produces no output.
local function run_agent(d: db.DB, system_prompt: string, model: string, prompt: string, parent_id: string, on_event: events.EventCallback)
  -- Load credentials to determine if OAuth mode
  local creds, creds_err = auth.load_credentials()
  if not creds then
    emit(on_event, events.error_event("credentials: " .. creds_err))
    return
  end
  local is_oauth = creds.is_oauth or false

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
        -- Check if result is structured (image content)
        local tool_output = block.tool_output as string
        local api_content: any = tool_output
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

  -- Agent loop
  while not interrupted do
    -- Emit api_call_start
    emit(on_event, events.api_call_start())

    -- Stream response (don't create message yet - wait until we have content)
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
    end)

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

    -- Collect response content blocks before writing to DB
    local resp = response as {string:any}
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

    -- Emit api_call_end with message metadata
    emit(on_event, events.api_call_end(
      assistant_msg.id,
      usage.input_tokens as integer,
      usage.output_tokens as integer,
      resp.api_latency_ms as integer,
      resp.model as string
    ))

    -- Log api_call_end event to DB
    db.log_event(d, "api_call_end", assistant_msg.id, events.to_json(events.api_call_end(
      assistant_msg.id,
      usage.input_tokens as integer,
      usage.output_tokens as integer,
      resp.api_latency_ms as integer,
      resp.model as string
    )))

    -- Add assistant message to API messages
    table.insert(api_messages, {role = "assistant", content = assistant_api_content})

    -- Check for tool calls
    local tool_calls = api.extract_tool_calls(response) as {any}
    if #tool_calls == 0 then
      final_stop_reason = resp.stop_reason as string or "end_turn"
      break  -- Done, no tool calls
    end

    -- Execute tool calls and collect results before writing to DB
    local tool_results_content: {any} = {}
    local tool_result_blocks: {{string:any}} = {}
    local think_time = (resp.think_time or 0) as number
    local tool_count = #tool_calls

    for i, tool_call in ipairs(tool_calls) do
      local tc = tool_call as {string:any}
      local input_json = json.encode(tc.input or {})
      local key = tool_key_param(tc.name as string, input_json)

      -- Emit tool_call_start
      emit(on_event, events.tool_call_start(tc.name as string, input_json, key, i, tool_count))

      local start = now()
      local result, is_error = tools.execute_tool(tc.name as string, (tc.input or {}) as {string:any})
      local elapsed = now() - start

      -- First tool includes think time in its timing
      if i == 1 then
        elapsed = elapsed + think_time
      end

      local elapsed_ms = math.floor(elapsed * 1000) as integer

      -- Emit tool_call_end
      emit(on_event, events.tool_call_end(tc.name as string, result, is_error, elapsed_ms, key, i, tool_count))

      -- Log tool_call_end event to DB
      db.log_event(d, "tool_call_end", assistant_msg.id, events.to_json(events.tool_call_end(tc.name as string, "", is_error, elapsed_ms, key, i, tool_count)))

      -- Check if result is structured (image content)
      local api_content: any = result
      if result:sub(1, 14) == '{"__image__":' then
        local parsed = json.decode(result) as {string:any}
        if parsed and parsed.__image__ and parsed.content then
          api_content = parsed.content
        end
      end

      -- Collect for later atomic write
      table.insert(tool_result_blocks, {
        tool_id = tc.id as string,
        tool_output = result,
        is_error = is_error,
        duration_ms = elapsed_ms,
      })

      -- Add to API messages content
      table.insert(tool_results_content, {
        type = "tool_result",
        tool_use_id = tc.id,
        content = api_content,
        is_error = is_error,
      })
    end

    -- Atomically write tool result message + all content blocks
    db.begin_transaction(d)
    local tool_result_msg = db.create_message(d, "user", assistant_msg.id)
    for _, blk in ipairs(tool_result_blocks) do
      db.add_content_block(d, tool_result_msg.id, "tool_result", {
        tool_id = blk.tool_id as string,
        tool_output = blk.tool_output as string,
        is_error = blk.is_error as boolean,
        duration_ms = blk.duration_ms as integer,
      })
    end
    db.commit(d)

    -- Add the tool results as a user message to API messages
    table.insert(api_messages, {role = "user", content = tool_results_content})

    -- Update user_msg for next iteration parent
    user_msg = tool_result_msg
    final_stop_reason = "tool_use"
  end

  if interrupted then
    final_stop_reason = "interrupted"
  end

  -- Emit agent_end
  emit(on_event, events.agent_end(final_stop_reason))

  -- Log agent_end event to DB
  db.log_event(d, "agent_end", nil, events.to_json(events.agent_end(final_stop_reason)))
end

return {
  run_agent = run_agent,
  tool_key_param = tool_key_param,
}
