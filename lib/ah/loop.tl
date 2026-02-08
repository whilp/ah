-- ah/loop.tl: agent loop (tool dispatch, display)
local json = require("cosmic.json")
local unix = require("cosmo.unix")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local auth = require("ah.auth")

-- Reference the global interrupted flag (set by application layer)
global interrupted: boolean

-- ANSI styling (only when stderr is a tty)
local is_tty = unix.isatty(2)
local DIM = is_tty and "\27[2m" or ""
local RESET = is_tty and "\27[0m" or ""

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

-- Send prompt and run agent loop
local function run_agent(d: db.DB, system_prompt: string, model: string, prompt: string, parent_id: string)
  -- Load credentials to determine if OAuth mode
  local creds, creds_err = auth.load_credentials()
  if not creds then
    io.stderr:write("error: " .. creds_err .. "\n")
    return
  end
  local is_oauth = creds.is_oauth or false

  -- Create user message (atomic: message + content block)
  db.begin_transaction(d)
  local user_msg = db.create_message(d, "user", parent_id)
  db.add_content_block(d, user_msg.id, "text", {content = prompt})
  db.commit(d)

  -- In non-interactive mode, echo the prompt for clarity
  if not is_tty then
    io.stderr:write(">>> " .. prompt .. "\n")
  end

  -- Build messages from ancestry (skip incomplete messages from crashes)
  local ancestry = db.get_ancestry(d, user_msg.id)
  local api_messages: {any} = {}

  for _, msg in ipairs(ancestry) do
    local blocks = db.get_content_blocks(d, msg.id)

    -- Skip messages with no content blocks (incomplete from crash)
    if #blocks == 0 then
      io.stderr:write(string.format("warning: skipping incomplete message %s (no content blocks)\n", msg.id))
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

  -- Agent loop
  while not interrupted do
    local current_text = ""

    -- Stream response (don't create message yet - wait until we have content)
    local response, err = api.stream(api_messages, {
      system = system_prompt,
      model = model,
      tools = tools.get_tool_definitions(),
    }, function(event: {string:any})
      if event.type == "content_block_delta" and event.delta then
        local delta = event.delta as {string:any}
        if delta.type == "text_delta" and delta.text then
          io.write(delta.text as string)
          io.flush()
          current_text = current_text .. (delta.text as string)
        end
      end
    end)

    if err then
      io.stderr:write("\nerror: " .. err .. "\n")
      return
    end

    if not response then
      io.stderr:write("\nerror: no response\n")
      return
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
      end
    end

    db.commit(d)

    -- Add assistant message to API messages
    table.insert(api_messages, {role = "assistant", content = assistant_api_content})

    -- Check for tool calls
    local tool_calls = api.extract_tool_calls(response) as {any}
    if #tool_calls == 0 then
      io.write("\n")
      break  -- Done, no tool calls
    end

    -- Execute tool calls and collect results before writing to DB
    -- Only add newline if there was response text
    if current_text ~= "" then
      io.write("\n")
    end

    local tool_results_content: {any} = {}
    local tool_result_blocks: {{string:any}} = {}
    local think_time = (resp.think_time or 0) as number

    for i, tool_call in ipairs(tool_calls) do
      local tc = tool_call as {string:any}
      local input_json = json.encode(tc.input or {})
      local key = tool_key_param(tc.name as string, input_json)

      local start = now()
      local result, is_error = tools.execute_tool(tc.name as string, (tc.input or {}) as {string:any})
      local elapsed = now() - start

      -- First tool includes think time in its timing
      if i == 1 then
        elapsed = elapsed + think_time
      end

      -- Show tool result block
      local prefix = is_tty and "⠋ " or ""
      local indent = "  "

      -- Blank line before first tool block only
      if i == 1 then
        io.stderr:write("\n")
      end

      -- Line 1: tool name and timing
      io.stderr:write(string.format("%s%s%s (%.1fs)%s\n", DIM, prefix, tc.name, elapsed, RESET))

      -- Line 2: command (for bash) or key param
      if key ~= "" then
        local cmd_prefix = tc.name == "bash" and "$ " or ""
        io.stderr:write(string.format("%s%s%s%s%s\n", DIM, indent, cmd_prefix, key, RESET))
      end

      -- Show truncated output (first 3 lines, then count)
      if result and result ~= "" and result ~= "(no output)" then
        local lines: {string} = {}
        for line in result:gmatch("[^\n]+") do
          table.insert(lines, line)
        end
        local max_lines = 3
        for j = 1, math.min(max_lines, #lines) do
          local line = lines[j]
          if #line > 80 then
            line = line:sub(1, 77) .. "..."
          end
          io.stderr:write(string.format("%s%s%s%s\n", DIM, indent, line, RESET))
        end
        if #lines > max_lines then
          io.stderr:write(string.format("%s%s... (%d more lines)%s\n", DIM, indent, #lines - max_lines, RESET))
        end
      end

      -- Blank line after tool block
      io.stderr:write("\n")

      -- Check if result is structured (image content)
      local api_content: any = result
      if result:sub(1, 14) == '{"__image__":' then
        local parsed = json.decode(result) as {string:any}
        if parsed and parsed.__image__ and parsed.content then
          api_content = parsed.content
        end
      end

      -- Collect for later atomic write (elapsed is in seconds, convert to ms)
      table.insert(tool_result_blocks, {
        tool_id = tc.id as string,
        tool_output = result,
        is_error = is_error,
        duration_ms = math.floor(elapsed * 1000) as integer,
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
  end
end

return {
  run_agent = run_agent,
  tool_key_param = tool_key_param,
}
