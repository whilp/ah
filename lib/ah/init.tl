-- ah/init.tl: agent loop and CLI interface
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")
local unix = require("cosmo.unix")

local cosmo = require("cosmo")
local zip = require("cosmic.zip")
local embed = require("cosmic.embed")
local pathlib = require("cosmo.path")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local auth = require("ah.auth")
local ulid = require("ulid")

-- Session record for listing
local record Session
  ulid: string
  db_path: string
  msg_count: integer
  first_prompt: string
  timestamp: number
end

-- Global for signal handling
global interrupted: boolean = false

-- ANSI styling (only when stderr is a tty)
local is_tty = unix.isatty(2)
local DIM = is_tty and "\27[2m" or ""
local RESET = is_tty and "\27[0m" or ""

-- Get monotonic time in seconds
local function now(): number
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return s + ns / 1e9
end

-- Load CLAUDE.md with embedded base prepended
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()
  local result = ""

  -- Load embedded base claude.md first
  local sys_claude = cio.slurp("/zip/embed/sys/claude.md")
  if sys_claude then
    result = "\n\n" .. sys_claude
  end

  -- Append project CLAUDE.md
  local project_claude = cio.slurp(fs.join(cwd, "CLAUDE.md"))
  if project_claude then
    result = result .. "\n\n# Project Context\n\n" .. project_claude
  end

  return result
end

-- Load system prompt with precedence:
-- 1. /zip/embed/system.md (user override)
-- 2. /zip/embed/sys/system.md (ah default)
-- CLAUDE.md is always appended
local function load_system_prompt(cwd: string): string
  cwd = cwd or fs.getcwd()
  local claude_md = load_claude_md(cwd)

  local user_system = cio.slurp("/zip/embed/system.md")
  if user_system then
    return user_system .. claude_md
  end

  local sys_system = cio.slurp("/zip/embed/sys/system.md")
  if sys_system then
    return sys_system .. claude_md
  end

  return claude_md
end

-- List session files from .ah/*.db with valid ULID names
local function list_sessions(cwd?: string): {Session}
  cwd = cwd or fs.getcwd()
  local ah_dir = fs.join(cwd, ".ah")
  local sessions: {Session} = {}

  local dir = unix.opendir(ah_dir)
  if not dir then
    return sessions
  end

  while true do
    local name = dir:read()
    if not name then break end

    -- Check if it's a .db file with ULID name
    if name:match("%.db$") then
      local session_ulid = name:sub(1, -4)  -- remove .db
      -- Validate ULID by checking length and trying to parse timestamp
      if #session_ulid == 26 then
        local ts = ulid.timestamp(session_ulid)
        if ts then
          local db_path = fs.join(ah_dir, name)
          local d = db.open(db_path)
          if d then
            table.insert(sessions, {
              ulid = session_ulid,
              db_path = db_path,
              msg_count = db.get_message_count(d),
              first_prompt = db.get_first_user_prompt(d),
              timestamp = ts,
            })
            db.close(d)
          end
        end
      end
    end
  end
  dir:close()

  -- Sort by ULID descending (most recent first - ULID encodes timestamp)
  table.sort(sessions, function(a: Session, b: Session): boolean
    return a.ulid > b.ulid
  end)

  return sessions
end

-- Resolve partial ULID prefix to full session ULID
local function resolve_session(cwd: string, prefix: string): string, string
  local sessions = list_sessions(cwd)
  local matches: {string} = {}

  for _, s in ipairs(sessions) do
    if s.ulid:sub(1, #prefix) == prefix then
      table.insert(matches, s.ulid)
    end
  end

  if #matches == 0 then
    return nil, "no session matches prefix: " .. prefix
  elseif #matches > 1 then
    return nil, "ambiguous prefix: " .. prefix .. " matches " .. #matches .. " sessions"
  end

  return matches[1], nil
end

local function usage()
  io.stderr:write([[usage: ah [options] [command] [args...]

commands:
  <prompt>            send prompt to agent
  (no args)           continue from last message
  @N <prompt>         fork from message N with new prompt
  sessions            list all sessions
  scan                list messages in current branch
  show [N]            show message(s)
  rmm N...            remove messages
  embed <dir>         embed files into /zip/embed/
  extract <dir>       extract /zip/embed/ to directory

options:
  -h, --help          show this help
  -n, --new           start a new session
  -S, --session ULID  use specific session (prefix match)
  --db PATH           use custom database path (default: .ah/<ulid>.db)
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
      tools = tools.get_tool_definitions(is_oauth),
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

-- List messages in current branch (ancestry from current message)
local function cmd_scan(d: db.DB)
  local current = db.get_current_message(d) as {string:any}
  if not current then
    -- Fall back to last message if current not set (e.g., after cleanup)
    current = db.get_last_message(d) as {string:any}
  end
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

-- List all sessions
local function cmd_sessions(cwd: string, current_ulid: string)
  local sessions = list_sessions(cwd)
  if #sessions == 0 then
    io.stderr:write("no sessions\n")
    return
  end

  for _, s in ipairs(sessions) do
    local marker = s.ulid == current_ulid and ">" or " "
    local decoded = ulid.decode(s.ulid)
    local time_str = decoded and decoded.time or "unknown"
    local preview = s.first_prompt:gsub("\n", " "):sub(1, 40)
    if #s.first_prompt > 40 then
      preview = preview .. "..."
    end
    io.write(string.format("%s %s  %s  %2d msgs  %s\n",
      marker, s.ulid, time_str, s.msg_count, preview))
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
  -- Enable core dumps for crash debugging
  -- RLIMIT_CORE = 4 on Linux, RLIM_INFINITY = -1
  unix.setrlimit(4, -1, -1)

  local model: string = nil
  local db_path: string = nil
  local output_path: string = nil
  local new_session: boolean = false
  local session_prefix: string = nil
  local cwd = fs.getcwd()

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "new", has_arg = "none", short = "n"},
    {name = "session", has_arg = "required", short = "S"},
    {name = "db", has_arg = "required"},
    {name = "model", has_arg = "required", short = "m"},
    {name = "output", has_arg = "required", short = "o"},
  }

  local parser = getopt.new(args, "hnS:m:o:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end

    if opt == "h" or opt == "help" then
      usage()
      return 0
    elseif opt == "n" or opt == "new" then
      new_session = true
    elseif opt == "S" or opt == "session" then
      session_prefix = optarg
    elseif opt == "db" then
      db_path = optarg
    elseif opt == "m" or opt == "model" then
      model = optarg
    elseif opt == "o" or opt == "output" then
      output_path = optarg
    elseif opt == "?" then
      usage()
      return 1
    end
  end

  local remaining = parser:remaining() or {}

  -- Handle commands that don't need db
  local cmd = remaining[1]
  if cmd == "sessions" then
    local sessions = list_sessions(cwd)
    local current_ulid = sessions[1] and sessions[1].ulid or ""
    cmd_sessions(cwd, current_ulid)
    return 0

  elseif cmd == "embed" then
    local src_dir = remaining[2]
    if not src_dir then
      io.stderr:write("usage: ah embed <dir> [-o <file>]\n")
      return 1
    end
    -- Create temp structure with embed/ prefix
    local tmpdir = unix.mkdtemp("/tmp/ah-embed-XXXXXX")
    local embed_link = pathlib.join(tmpdir, "embed")
    unix.symlink(fs.realpath(src_dir), embed_link)
    local result = embed.run({tmpdir}, output_path)
    unix.rmrf(tmpdir)
    if result.ok then
      io.write(result.message .. "\n")
      return 0
    else
      io.stderr:write("embed: " .. result.message .. "\n")
      return 1
    end

  elseif cmd == "extract" then
    local output_dir = remaining[2]
    if not output_dir then
      io.stderr:write("usage: ah extract <dir>\n")
      return 1
    end
    -- Extract only files from embed/ prefix
    local exe_path = arg[-1]
    local exe_data = cosmo.Slurp(exe_path)
    if not exe_data then
      io.stderr:write("extract: cannot read executable\n")
      return 1
    end
    local reader, err = zip.from(exe_data)
    if not reader then
      io.stderr:write("extract: " .. (err or "no zip archive found") .. "\n")
      return 1
    end
    local prefix = "embed/"
    local entries = reader:list()
    local count = 0
    for _, name in ipairs(entries) do
      if name:sub(1, #prefix) == prefix and name:sub(-1) ~= "/" then
        local content = reader:read(name)
        if content then
          local rel_name = name:sub(#prefix + 1)
          local filepath = pathlib.join(output_dir, rel_name)
          local dir = pathlib.dirname(filepath)
          unix.makedirs(dir)
          cosmo.Barf(filepath, content)
          count = count + 1
        end
      end
    end
    reader:close()
    io.write("extracted " .. count .. " file(s) to " .. output_dir .. "\n")
    return 0
  end

  -- Session selection logic (only if --db not specified)
  local session_ulid: string = nil
  if not db_path then
    local ah_dir = fs.join(cwd, ".ah")
    fs.makedirs(ah_dir)

    if new_session then
      -- -n: force new session
      session_ulid = ulid.generate()
    elseif session_prefix then
      -- -S PREFIX: resolve to specific session
      local resolved, err = resolve_session(cwd, session_prefix)
      if not resolved then
        return 1, err
      end
      session_ulid = resolved
    else
      -- Default: use most recent session or create new if needed
      local sessions = list_sessions(cwd)
      if #sessions > 0 then
        session_ulid = sessions[1].ulid
      else
        -- No existing sessions - will create new if prompt given
        session_ulid = ulid.generate()
      end
    end

    db_path = fs.join(ah_dir, session_ulid .. ".db")
  end

  local d, err = db.open(db_path)
  if not d then
    return 1, err
  end

  -- Clean up any orphan messages from previous crashes
  local orphans_cleaned = db.cleanup_orphans(d)
  if orphans_cleaned > 0 then
    io.stderr:write(string.format("cleaned up %d orphan message(s) from previous crash\n", orphans_cleaned))
  end

  -- Handle commands
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

  -- If no prompt, read from stdin
  if prompt == "" then
    -- Show prompt indicator if stdin is a tty
    if unix.isatty(0) then
      io.stderr:write(">>> ")
      io.stderr:flush()
    end
    local ok, input = pcall(io.read, "*a")
    if not ok or not input then
      -- Interrupted or EOF
      io.stderr:write("\n")
      db.close(d)
      return 0
    end
    prompt = input
    -- Trim trailing newline
    prompt = prompt:gsub("%s+$", "")
    if prompt == "" then
      usage()
      db.close(d)
      return 0
    end
  end

  -- Load system prompt
  local effective_system = load_system_prompt(cwd)

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
  list_sessions = list_sessions,
  resolve_session = resolve_session,
}
