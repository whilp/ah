-- ah/looptool.tl: tool execution within the agent loop
local json = require("cosmic.json")
local time = require("cosmic.time")
local db = require("ah.db")
local tools = require("ah.tools")
local events = require("ah.events")
local truncate = require("ah.truncate")
local looputil = require("ah.looputil")

-- Reference the global interrupted flag
global interrupted: boolean

-- Get monotonic time in seconds
local function now(): number
  local s, ns = time.monotonic()
  return s + ns / 1e9
end

-- Emit an event through the callback
local function emit(on_event: events.EventCallback, event: events.EventData)
  if on_event then
    on_event(event)
  end
end

-- Result of executing all tool calls in a turn
local record ToolExecResult
  tool_result_blocks: {{string: any}}
  tool_results_content: {any}
  was_interrupted: boolean
end

-- Execute all tool calls for a turn, emitting events and handling interruption.
-- Returns the collected results for DB persistence and API message building.
local function execute_tool_calls(
    tool_calls: {any},
    think_time: number,
    assistant_msg_id: string,
    d: db.DB,
    on_event: events.EventCallback
  ): ToolExecResult

  local tool_results_content: {any} = {}
  local tool_result_blocks: {{string: any}} = {}
  local tool_count = #tool_calls

  for i, tool_call in ipairs(tool_calls) do
    if interrupted then
      tools.abort_running_tools()
      return {
        tool_result_blocks = tool_result_blocks,
        tool_results_content = tool_results_content,
        was_interrupted = true,
      }
    end

    local tc = tool_call as {string: any}
    local input_json = json.encode(tc.input or {})
    local key = looputil.tool_key_display(tc.name as string, input_json, nil)

    emit(on_event, events.tool_call_start(tc.name as string, input_json, key, i, tool_count))

    local start = now()
    local result, is_error, details = tools.execute_tool(tc.name as string, (tc.input or {}) as {string: any})
    local elapsed = now() - start

    if interrupted then
      tools.abort_running_tools()
      local elapsed_ms = math.floor(elapsed * 1000) as integer
      emit(on_event, events.tool_call_end(tc.name as string, result, is_error, elapsed_ms, key, i, tool_count))
      db.log_event(d, "tool_call_end", assistant_msg_id, events.to_json(events.tool_call_end(tc.name as string, "", is_error, elapsed_ms, key, i, tool_count)))

      local int_details_json: string = nil
      if details then
        int_details_json = json.encode(details as {string: any})
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
      return {
        tool_result_blocks = tool_result_blocks,
        tool_results_content = tool_results_content,
        was_interrupted = true,
      }
    end

    -- First tool includes think time in its timing
    if i == 1 then
      elapsed = elapsed + think_time
    end

    local elapsed_ms = math.floor(elapsed * 1000) as integer

    local details_json: string = nil
    if details then
      details_json = json.encode(details as {string: any})
    end

    -- Recompute key with details for richer display
    key = looputil.tool_key_display(tc.name as string, input_json, details_json)

    emit(on_event, events.tool_call_end(tc.name as string, result, is_error, elapsed_ms, key, i, tool_count))
    db.log_event(d, "tool_call_end", assistant_msg_id, events.to_json(events.tool_call_end(tc.name as string, "", is_error, elapsed_ms, key, i, tool_count)))

    -- Truncate output for the API (full output preserved in DB and events)
    local truncation = truncate.truncate_output(result, tc.name as string)
    local api_result = truncation.content

    -- Check if result is structured (image content)
    local api_content: any = api_result
    if result:sub(1, 14) == '{"__image__":' then
      local parsed = json.decode(result) as {string: any}
      if parsed and parsed.__image__ and parsed.content then
        api_content = parsed.content
      end
    end

    table.insert(tool_result_blocks, {
        tool_id = tc.id as string,
        tool_output = result,
        is_error = is_error,
        duration_ms = elapsed_ms,
        details = details_json,
      })
    table.insert(tool_results_content, {
        type = "tool_result",
        tool_use_id = tc.id,
        content = api_content,
        is_error = is_error,
      })
  end

  return {
    tool_result_blocks = tool_result_blocks,
    tool_results_content = tool_results_content,
    was_interrupted = false,
  }
end

-- Persist tool results to DB and add to API messages.
-- Returns the new user message (tool result message).
local function persist_tool_results(
    d: db.DB,
    assistant_msg_id: string,
    result: ToolExecResult,
    api_messages: {any}
  ): db.Message

  if #result.tool_result_blocks == 0 then
    return nil
  end

  db.begin_transaction(d)
  local tool_result_msg = db.create_message(d, "user", assistant_msg_id)
  for _, blk in ipairs(result.tool_result_blocks) do
    db.add_content_block(d, tool_result_msg.id, "tool_result", {
        tool_id = blk.tool_id as string,
        tool_output = blk.tool_output as string,
        is_error = blk.is_error as boolean,
        duration_ms = blk.duration_ms as integer,
        details = blk.details as string,
      })
  end
  db.commit(d)

  table.insert(api_messages, {role = "user", content = result.tool_results_content})

  return tool_result_msg
end

return {
  execute_tool_calls = execute_tool_calls,
  persist_tool_results = persist_tool_results,
  ToolExecResult = ToolExecResult,
}
