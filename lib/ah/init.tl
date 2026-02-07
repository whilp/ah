-- ah/init.tl: agent loop and CLI interface
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local getopt = require("cosmo.getopt")

local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")

-- Global for signal handling
global interrupted: boolean = false

local function usage()
  io.stderr:write([[usage: ah [options] [command] [args...]

commands:
  <prompt>            send prompt to agent
  (no args)           continue from last message
  @N <prompt>         fork from message N with new prompt
  folder [+name]      list or switch sessions
  scan [+name]        list messages in session
  show [N]            show message(s)
  rmm N...            remove messages
  rmf [+name]         remove session

options:
  -h, --help          show this help
  -n, --new [+name]   start new session (optionally named)
  -s, --system PROMPT set system prompt
]])
end

-- Extract key parameter from tool input for display
local function tool_key_param(tool_name: string, tool_input: string): string
  if not tool_input then return "" end
  local input = cosmo.DecodeJson(tool_input) as {string:any}
  if not input then return "" end

  if tool_name == "read" or tool_name == "write" then
    return (input.path or "") as string
  elseif tool_name == "edit" then
    return string.format("%s: %s → %s", input.path or "",
      ((input.old_string or "") as string):sub(1, 20),
      ((input.new_string or "") as string):sub(1, 20))
  elseif tool_name == "bash" then
    return (input.command or "") as string
  end
  return ""
end

-- Send prompt and run agent loop
local function run_agent(d: any, session: {string:any}, prompt: string, parent_id: string)
  -- Create user message
  local user_msg = db.create_message(d, session.id as string, "user", parent_id) as {string:any}
  db.add_content_block(d, user_msg.id as string, "text", {content = prompt})

  -- Build messages from ancestry
  local ancestry = db.get_ancestry(d, user_msg.id as string) as {{string:any}}
  local api_messages: {any} = {}

  for _, msg in ipairs(ancestry) do
    local blocks = db.get_content_blocks(d, msg.id as string) as {{string:any}}
    local content: {any} = {}

    for _, block in ipairs(blocks) do
      if block.block_type == "text" then
        table.insert(content, {type = "text", text = block.content})
      elseif block.block_type == "tool_use" then
        local input = block.tool_input and cosmo.DecodeJson(block.tool_input as string) or {}
        table.insert(content, {
          type = "tool_use",
          id = block.tool_id,
          name = block.tool_name,
          input = input,
        })
      elseif block.block_type == "tool_result" then
        table.insert(content, {
          type = "tool_result",
          tool_use_id = block.tool_id,
          content = block.tool_output,
          is_error = block.is_error == 1,
        })
      end
    end

    table.insert(api_messages, {
      role = msg.role,
      content = content,
    })
  end

  -- Agent loop
  while not interrupted do
    -- Create assistant message
    local assistant_msg = db.create_message(d, session.id as string, "assistant", user_msg.id as string) as {string:any}
    local current_text = ""

    -- Stream response
    local response, err = api.stream(api_messages, {
      system = session.system_prompt as string,
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

    -- Save response content blocks and build assistant message for API
    local resp = response as {string:any}
    local resp_content = resp.content as {any}
    local assistant_api_content: {any} = {}

    for _, block in ipairs(resp_content) do
      local b = block as {string:any}
      if b.type == "text" then
        db.add_content_block(d, assistant_msg.id as string, "text", {content = b.text})
        table.insert(assistant_api_content, {type = "text", text = b.text})
      elseif b.type == "tool_use" then
        local input_json = cosmo.EncodeJson(b.input or {})
        db.add_content_block(d, assistant_msg.id as string, "tool_use", {
          tool_id = b.id,
          tool_name = b.name,
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

    -- Add assistant message to API messages
    table.insert(api_messages, {role = "assistant", content = assistant_api_content})

    -- Check for tool calls
    local tool_calls = api.extract_tool_calls(response) as {any}
    if #tool_calls == 0 then
      io.write("\n")
      break  -- Done, no tool calls
    end

    -- Execute tool calls and create user message for results
    io.write("\n")

    -- Create a new user message for tool results (child of assistant message)
    local tool_result_msg = db.create_message(d, session.id as string, "user", assistant_msg.id as string) as {string:any}

    -- Add tool results to API messages
    local tool_results_content: {any} = {}

    for _, tool_call in ipairs(tool_calls) do
      local tc = tool_call as {string:any}
      io.stderr:write(string.format("→ %s\n", tc.name))

      local result, is_error = tools.execute_tool(tc.name as string, (tc.input or {}) as {string:any})

      -- Save tool result to the new user message
      db.add_content_block(d, tool_result_msg.id as string, "tool_result", {
        tool_id = tc.id,
        tool_output = result,
        is_error = is_error,
      })

      -- Add to API messages content
      table.insert(tool_results_content, {
        type = "tool_result",
        tool_use_id = tc.id,
        content = result,
        is_error = is_error,
      })
    end

    -- Add the tool results as a user message to API messages
    table.insert(api_messages, {role = "user", content = tool_results_content})

    -- Update user_msg for next iteration parent
    user_msg = tool_result_msg
  end
end

-- Format relative time
local function relative_time(ts: integer): string
  local now = os.time()
  local diff = now - ts
  if diff < 60 then return "now"
  elseif diff < 3600 then return string.format("%dm", math.floor(diff / 60))
  elseif diff < 86400 then return string.format("%dh", math.floor(diff / 3600))
  elseif diff < 604800 then return string.format("%dd", math.floor(diff / 86400))
  else return string.format("%dw", math.floor(diff / 604800))
  end
end

-- List sessions
local function cmd_folder(d: any, name: string)
  if name then
    -- Switch to session by name
    local session = db.get_session_by_name(d, name)
    if not session then
      io.stderr:write("session not found: " .. name .. "\n")
      return
    end
    db.set_current_session(d, session.id)
    io.write("switched to " .. name .. "\n")
  else
    -- List sessions
    local sessions = db.list_sessions(d) as {any}
    local current = db.get_current_session(d)
    local current_id = current and current.id or nil

    for _, session in ipairs(sessions) do
      local s = session as {string:any}
      local marker = (current_id and current_id == s.id) and "*" or " "
      local name_str = (s.name or (s.id as string):sub(1, 8)) as string
      local msg_count = (s.message_count or 0) as integer
      local age = relative_time(s.updated_at as integer)
      io.write(string.format("%s %-12s %3d msgs  %s\n", marker, name_str, msg_count, age))
    end
  end
end

-- List messages in current branch (ancestry from current message)
local function cmd_scan(d: any, name: string)
  local session: {string:any}
  if name then
    session = db.get_session_by_name(d, name) as {string:any}
    if not session then
      io.stderr:write("session not found: " .. name .. "\n")
      return
    end
  else
    session = db.get_current_session(d) as {string:any}
    if not session then
      io.stderr:write("no current session\n")
      return
    end
  end

  local current = db.get_current_message(d) as {string:any}
  if not current then
    io.stderr:write("no messages\n")
    return
  end

  -- Get ancestry (current branch only)
  local messages = db.get_ancestry(d, current.id as string) as {{string:any}}

  for i, m in ipairs(messages) do
    local blocks = db.get_content_blocks(d, m.id as string) as {{string:any}}
    local is_current = (i == #messages)
    local marker = is_current and ">" or " "

    -- Role indicator
    local role_char = m.role == "user" and "U" or "A"

    -- Check if this is a tool-result-only message (skip display, show inline)
    local has_text = false
    local has_tool_result = false
    for _, b in ipairs(blocks) do
      if b.block_type == "text" and b.content and (b.content as string):match("%S") then
        has_text = true
      elseif b.block_type == "tool_result" then
        has_tool_result = true
      end
    end

    -- Skip pure tool-result messages (they're shown inline with previous assistant)
    if has_tool_result and not has_text then
      goto continue
    end

    -- Build preview
    local preview = ""
    local tool_calls: {string} = {}

    for _, b in ipairs(blocks) do
      if b.block_type == "text" and b.content then
        local text = (b.content as string):gsub("\n", " "):sub(1, 60)
        if #(b.content as string) > 60 then
          text = text .. "..."
        end
        preview = text
      elseif b.block_type == "tool_use" then
        local key = tool_key_param(b.tool_name as string, b.tool_input as string)
        if #key > 40 then key = key:sub(1, 40) .. "..." end
        local suffix = key ~= "" and " " .. key or ""
        table.insert(tool_calls, string.format("→ %s%s", b.tool_name, suffix))
      end
    end

    -- Print message line
    io.write(string.format("%s%3d %s: %s\n", marker, m.seq as integer, role_char, preview))

    -- Print tool calls on separate lines
    for _, tc in ipairs(tool_calls) do
      io.write(string.format("       %s\n", tc))
    end

    ::continue::
  end
end

-- Show message content
local function cmd_show(d: any, seq: integer)
  local session = db.get_current_session(d) as {string:any}
  if not session then
    io.stderr:write("no current session\n")
    return
  end

  local m: {string:any}
  if seq then
    m = db.get_message_by_seq(d, session.id as string, seq) as {string:any}
    if not m then
      io.stderr:write("message not found: @" .. seq .. "\n")
      return
    end
  else
    m = db.get_current_message(d) as {string:any}
    if not m then
      io.stderr:write("no current message\n")
      return
    end
  end

  local blocks = db.get_content_blocks(d, m.id as string) as {{string:any}}
  io.write(string.format("--- %s @%d ---\n", m.role, m.seq as integer))
  for _, b in ipairs(blocks) do
    if b.block_type == "text" then
      io.write((b.content or "") as string)
      io.write("\n")
    elseif b.block_type == "tool_use" then
      local key = tool_key_param(b.tool_name as string, b.tool_input as string)
      io.write(string.format("→ %s %s\n", b.tool_name, key))
    elseif b.block_type == "tool_result" then
      local output = ((b.tool_output or "") as string)
      local lines = {}
      for line in output:gmatch("[^\n]+") do
        table.insert(lines, line)
        if #lines >= 5 then break end
      end
      io.write(string.format("← %s\n", table.concat(lines, "\n  ")))
    end
  end
end

-- Remove messages
local function cmd_rmm(d: any, seqs: {integer})
  local session = db.get_current_session(d)
  if not session then
    io.stderr:write("no current session\n")
    return
  end

  for _, seq in ipairs(seqs) do
    local msg = db.get_message_by_seq(d, session.id, seq)
    if msg then
      db.delete_message(d, msg.id)
      io.write("deleted @" .. seq .. "\n")
    else
      io.stderr:write("message not found: @" .. seq .. "\n")
    end
  end
end

-- Remove session
local function cmd_rmf(d: any, name: string)
  local session: any
  if name then
    session = db.get_session_by_name(d, name)
    if not session then
      io.stderr:write("session not found: " .. name .. "\n")
      return
    end
  else
    session = db.get_current_session(d)
    if not session then
      io.stderr:write("no current session\n")
      return
    end
  end

  local s = session as {string:any}
  db.delete_session(d, s.id as string)
  io.write("deleted " .. ((s.name or s.id) as string) .. "\n")
end

local function main(args: {string}): integer, string
  local new_session = false
  local system_prompt: string = nil

  local longopts = {
    {"help", "none"},
    {"new", "none"},
    {"system", "required"},
  }

  local parser = getopt.new(args, "hns:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end

    if opt == "h" or opt == "help" then
      usage()
      return 0
    elseif opt == "n" or opt == "new" then
      new_session = true
    elseif opt == "s" or opt == "system" then
      system_prompt = optarg
    elseif opt == "?" then
      usage()
      return 1
    end
  end

  local remaining = parser:remaining() or {}

  local d, err = db.open()
  if not d then
    return 1, err
  end

  -- Handle commands
  local cmd = remaining[1]

  if cmd == "folder" then
    local name = remaining[2]
    if name and name:sub(1, 1) == "+" then
      name = name:sub(2)
    end
    cmd_folder(d, name)
    db.close(d)
    return 0

  elseif cmd == "scan" then
    local name = remaining[2]
    if name and name:sub(1, 1) == "+" then
      name = name:sub(2)
    end
    cmd_scan(d, name)
    db.close(d)
    return 0

  elseif cmd == "show" then
    local seq_str = remaining[2]
    local seq: integer = nil
    if seq_str then
      seq = tonumber(seq_str) as integer
    end
    cmd_show(d, seq)
    db.close(d)
    return 0

  elseif cmd == "rmm" then
    local seqs: {integer} = {}
    for i = 2, #remaining do
      table.insert(seqs, tonumber(remaining[i]) as integer)
    end
    cmd_rmm(d, seqs)
    db.close(d)
    return 0

  elseif cmd == "rmf" then
    local name = remaining[2]
    if name and name:sub(1, 1) == "+" then
      name = name:sub(2)
    end
    cmd_rmf(d, name)
    db.close(d)
    return 0
  end

  -- Handle prompt or continue
  local session = db.get_current_session(d)
  local parent_id: string = nil
  local prompt: string = nil
  local session_name: string = nil

  -- Check for +name when starting new session
  if new_session and cmd and cmd:sub(1, 1) == "+" then
    session_name = cmd:sub(2)
    table.remove(remaining, 1)
    cmd = remaining[1]
  end

  -- Check for @N fork syntax
  if cmd and cmd:sub(1, 1) == "@" then
    local seq = tonumber(cmd:sub(2)) as integer
    if not seq then
      db.close(d)
      return 1, "invalid message number: " .. cmd
    end

    if not session then
      db.close(d)
      return 1, "no current session"
    end

    local msg = db.get_message_by_seq(d, session.id, seq)
    if not msg then
      db.close(d)
      return 1, "message not found: " .. cmd
    end

    parent_id = msg.id
    prompt = table.concat(remaining, " ", 2)
  else
    prompt = table.concat(remaining, " ")
  end

  -- Create or get session
  if new_session or not session then
    session = db.create_session(d, session_name, unix.getcwd(), system_prompt)
  end

  -- Get parent message - always continue from last message unless forking with @N
  if not parent_id then
    local last = db.get_last_message(d, session.id as string)
    if last then
      parent_id = (last as {string:any}).id as string
    end
    -- If no last message and no prompt, error
    if not parent_id and prompt == "" then
      db.close(d)
      return 1, "no messages to continue from"
    end
  end

  -- If no prompt, show help
  if prompt == "" and not parent_id then
    usage()
    db.close(d)
    return 0
  end

  -- Run agent
  run_agent(d, session, prompt, parent_id)

  db.close(d)
  return 0
end

if cosmo.is_main() then
  local code, err = main(arg)
  if err then
    io.stderr:write("error: " .. err .. "\n")
  end
  os.exit(code)
end

return {
  main = main,
}
