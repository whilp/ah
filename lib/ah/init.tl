-- ah/init.tl: agent loop and CLI interface
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")
local unix = require("cosmo.unix")

local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")

-- Global for signal handling
global interrupted: boolean = false

local DEFAULT_SYSTEM_PROMPT = [[You are a coding assistant. Tools: read, write, edit, bash.
read: examine files. edit: precise text replacement. write: create new files. bash: run commands.]]

-- Load CLAUDE.md from current directory
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()
  local content = cio.slurp(fs.join(cwd, "CLAUDE.md"))
  if content then
    return "\n\n# Project Context\n\n" .. content
  end
  return ""
end

-- Load system prompt with precedence:
-- 1. cli_system (via -s flag) if set
-- 2. .ah/SYSTEM.md (project) if exists
-- 3. DEFAULT_SYSTEM_PROMPT
-- CLAUDE.md is always appended
local function load_system_prompt(cli_system: string, cwd: string): string
  cwd = cwd or fs.getcwd()
  local claude_md = load_claude_md(cwd)

  if cli_system then
    return cli_system .. claude_md
  end

  local project_system = cio.slurp(fs.join(cwd, ".ah", "SYSTEM.md"))
  if project_system then
    return project_system .. claude_md
  end

  return DEFAULT_SYSTEM_PROMPT .. claude_md
end

local function usage()
  io.stderr:write([[usage: ah [options] [command] [args...]

commands:
  <prompt>            send prompt to agent
  (no args)           continue from last message
  @N <prompt>         fork from message N with new prompt
  scan                list messages in current branch
  show [N]            show message(s)
  rmm N...            remove messages

options:
  -h, --help          show this help
  --db PATH           use custom database path (default: .ah/ah.db)
  -s, --system PROMPT set system prompt for this invocation
  -m, --model MODEL   set model (e.g., claude-sonnet-4-20250514)
]])
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
  -- Create user message
  local user_msg = db.create_message(d, "user", parent_id)
  db.add_content_block(d, user_msg.id, "text", {content = prompt})

  -- Build messages from ancestry
  local ancestry = db.get_ancestry(d, user_msg.id)
  local api_messages: {any} = {}

  for _, msg in ipairs(ancestry) do
    local blocks = db.get_content_blocks(d, msg.id)
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
  end

  -- Agent loop
  while not interrupted do
    -- Create assistant message
    local assistant_msg = db.create_message(d, "assistant", user_msg.id)
    local current_text = ""

    -- Stream response
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

    -- Save response content blocks and build assistant message for API
    local resp = response as {string:any}
    local resp_content = resp.content as {any}
    local assistant_api_content: {any} = {}

    for _, block in ipairs(resp_content) do
      local b = block as {string:any}
      if b.type == "text" then
        db.add_content_block(d, assistant_msg.id, "text", {content = b.text as string})
        table.insert(assistant_api_content, {type = "text", text = b.text})
      elseif b.type == "tool_use" then
        local input_json = json.encode(b.input or {})
        db.add_content_block(d, assistant_msg.id, "tool_use", {
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
    local tool_result_msg = db.create_message(d, "user", assistant_msg.id)

    -- Add tool results to API messages
    local tool_results_content: {any} = {}

    for _, tool_call in ipairs(tool_calls) do
      local tc = tool_call as {string:any}
      local input_json = json.encode(tc.input or {})
      local key = tool_key_param(tc.name as string, input_json)
      if key ~= "" then
        io.stderr:write(string.format("→ %s %s\n", tc.name, key))
      else
        io.stderr:write(string.format("→ %s\n", tc.name))
      end

      local result, is_error = tools.execute_tool(tc.name as string, (tc.input or {}) as {string:any})

      -- Check if result is structured (image content)
      local api_content: any = result
      if result:sub(1, 14) == '{"__image__":' then
        local parsed = json.decode(result) as {string:any}
        if parsed and parsed.__image__ and parsed.content then
          api_content = parsed.content
        end
      end

      -- Save tool result to the new user message
      db.add_content_block(d, tool_result_msg.id, "tool_result", {
        tool_id = tc.id as string,
        tool_output = result,
        is_error = is_error,
      })

      -- Add to API messages content
      table.insert(tool_results_content, {
        type = "tool_result",
        tool_use_id = tc.id,
        content = api_content,
        is_error = is_error,
      })
    end

    -- Add the tool results as a user message to API messages
    table.insert(api_messages, {role = "user", content = tool_results_content})

    -- Update user_msg for next iteration parent
    user_msg = tool_result_msg
  end
end

-- List messages in current branch (ancestry from current message)
local function cmd_scan(d: db.DB)
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
local function cmd_show(d: db.DB, seq: integer)
  local m: db.Message
  if seq then
    m = db.get_message_by_seq(d, seq)
    if not m then
      io.stderr:write("message not found: @" .. seq .. "\n")
      return
    end
  else
    m = db.get_current_message(d)
    if not m then
      io.stderr:write("no current message\n")
      return
    end
  end

  local blocks = db.get_content_blocks(d, m.id)
  io.write(string.format("--- %s @%d ---\n", m.role, m.seq))
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
local function cmd_rmm(d: db.DB, seqs: {integer})
  for _, seq in ipairs(seqs) do
    local msg = db.get_message_by_seq(d, seq)
    if msg then
      db.delete_message(d, msg.id)
      io.write("deleted @" .. seq .. "\n")
    else
      io.stderr:write("message not found: @" .. seq .. "\n")
    end
  end
end

local function main(args: {string}): integer, string
  local system_prompt: string = nil
  local model: string = nil
  local db_path: string = nil

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "db", has_arg = "required"},
    {name = "system", has_arg = "required", short = "s"},
    {name = "model", has_arg = "required", short = "m"},
  }

  local parser = getopt.new(args, "hs:m:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end

    if opt == "h" or opt == "help" then
      usage()
      return 0
    elseif opt == "db" then
      db_path = optarg
    elseif opt == "s" or opt == "system" then
      system_prompt = optarg
    elseif opt == "m" or opt == "model" then
      model = optarg
    elseif opt == "?" then
      usage()
      return 1
    end
  end

  local remaining = parser:remaining() or {}

  local d, err = db.open(db_path)
  if not d then
    return 1, err
  end

  -- Handle commands
  local cmd = remaining[1]

  if cmd == "scan" then
    cmd_scan(d)
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
  end

  -- Handle prompt or continue
  local parent_id: string = nil
  local prompt: string = nil

  -- Check for @N fork syntax
  if cmd and cmd:sub(1, 1) == "@" then
    local seq = tonumber(cmd:sub(2)) as integer
    if not seq then
      db.close(d)
      return 1, "invalid message number: " .. cmd
    end

    local msg = db.get_message_by_seq(d, seq)
    if not msg then
      db.close(d)
      return 1, "message not found: " .. cmd
    end

    parent_id = msg.id
    prompt = table.concat(remaining, " ", 2)
  else
    prompt = table.concat(remaining, " ")
  end

  -- Get parent message - always continue from last message unless forking with @N
  if not parent_id then
    local last = db.get_last_message(d)
    if last then
      parent_id = (last as {string:any}).id as string
    end
  end

  -- If no prompt, need either something to continue or show help
  if prompt == "" then
    if not parent_id then
      usage()
      db.close(d)
      return 0
    else
      db.close(d)
      return 1, "no prompt provided"
    end
  end

  -- Load system prompt
  local effective_system = load_system_prompt(system_prompt, nil)

  -- Initialize custom tools
  tools.init_custom_tools()

  -- Install SIGINT handler for graceful Ctrl+C
  unix.sigaction(unix.SIGINT, function()
    interrupted = true
  end)

  -- Run agent
  run_agent(d, effective_system, model, prompt, parent_id)

  db.close(d)
  return 0
end

return {
  main = main,
  load_system_prompt = load_system_prompt,
  load_claude_md = load_claude_md,
  tool_key_param = tool_key_param,
  DEFAULT_SYSTEM_PROMPT = DEFAULT_SYSTEM_PROMPT,
}
