-- ah/init.tl: CLI interface, session management, prompt expansion
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local getopt = require("cosmic.getopt")
local unix = require("cosmo.unix")

local cosmo = require("cosmo")
local zip = require("cosmic.zip")
local embed = require("cosmic.embed")
local pathlib = require("cosmo.path")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local commands = require("ah.commands")
local skills = require("ah.skills")
local loop = require("ah.loop")
local events = require("ah.events")
local ulid = require("ulid")
local queue = require("ah.queue")

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
  -m, --model MODEL   set model (default: sonnet)
  --steer MSG         send steering message to running session
  --followup MSG      queue followup message for after session completes

models:
]])
  for alias, full in pairs(api.MODEL_ALIASES) do
    io.stderr:write(string.format("  %-18s  %s\n", alias, full))
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
        local key = loop.tool_key_param(b.tool_name as string, b.tool_input as string, b.details as string)
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
      local key = loop.tool_key_param(b.tool_name as string, b.tool_input as string, b.details as string)
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

-- CLI display handler: renders structured events to stderr/stdout for terminal use.
-- This is the application-layer implementation of the event callback.
-- Other handlers (JSON logging, web UI, etc.) can be substituted.
local function make_cli_handler(): events.EventCallback
  local is_tty = unix.isatty(2)
  local DIM = is_tty and "\27[2m" or ""
  local RESET = is_tty and "\27[0m" or ""
  local has_text = false

  return function(event: events.EventData)
    local t = event.event_type

    if t == "agent_start" then
      -- In non-interactive mode, echo the prompt for clarity
      if not is_tty and event.prompt then
        io.stderr:write(">>> " .. event.prompt .. "\n")
      end

    elseif t == "text_delta" then
      io.write(event.text)
      io.flush()
      has_text = true

    elseif t == "agent_end" then
      -- Trailing newline after text output
      if has_text then
        io.write("\n")
      end

    elseif t == "error" then
      io.stderr:write("\nerror: " .. (event.error or "unknown") .. "\n")

    elseif t == "api_call_end" then
      -- Text output complete for this turn; check if tool calls follow
      -- (tool_call_start will handle the newline separator)

    elseif t == "tool_call_start" then
      -- Separator between text and first tool block
      if event.tool_index == 1 then
        if has_text then
          io.write("\n")
          has_text = false
        end
        io.stderr:write("\n")
      end

    elseif t == "tool_call_end" then
      local prefix = is_tty and "⠋ " or ""
      local indent = "  "
      local elapsed = (event.duration_ms or 0) / 1000

      -- Line 1: tool name and timing
      io.stderr:write(string.format("%s%s%s (%.1fs)%s\n", DIM, prefix, event.tool_name, elapsed, RESET))

      -- Line 2: command (for bash) or key param
      local key = event.tool_key or ""
      if key ~= "" then
        local cmd_prefix = event.tool_name == "bash" and "$ " or ""
        io.stderr:write(string.format("%s%s%s%s%s\n", DIM, indent, cmd_prefix, key, RESET))
      end

      -- Show truncated output (first 3 lines, then count)
      local result = event.tool_output or ""
      if result ~= "" and result ~= "(no output)" then
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
  local steer_msg: string = nil
  local followup_msg: string = nil
  local cwd = fs.getcwd()

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "new", has_arg = "none", short = "n"},
    {name = "session", has_arg = "required", short = "S"},
    {name = "db", has_arg = "required"},
    {name = "model", has_arg = "required", short = "m"},
    {name = "output", has_arg = "required", short = "o"},
    {name = "steer", has_arg = "required"},
    {name = "followup", has_arg = "required"},
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
    elseif opt == "steer" then
      steer_msg = optarg
    elseif opt == "followup" then
      followup_msg = optarg
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

  -- Queue path is derived from session (same directory as db)
  local queue_path = db_path:gsub("%.db$", ".queue.db")

  -- Handle --steer and --followup options (queue and exit)
  if steer_msg or followup_msg then
    local qdb, qerr = queue.open(queue_path)
    if not qdb then
      return 1, qerr
    end

    if steer_msg then
      queue.add_steer(qdb, steer_msg)
      io.stderr:write("queued steering message\n")
    end
    if followup_msg then
      queue.add_followup(qdb, followup_msg)
      io.stderr:write("queued followup message\n")
    end

    queue.close(qdb)
    return 0
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

  -- Open queue database (will be used for lock management and steering/followup)
  local qdb, qerr = queue.open(queue_path)
  if not qdb then
    db.close(d)
    return 1, qerr
  end

  -- Handle commands (no lock needed for read-only commands)
  if cmd == "scan" then
    cmd_scan(d)
    queue.close(qdb)
    db.close(d)
    return 0

  elseif cmd == "show" then
    local seq_str = remaining[2]
    local seq: integer = nil
    if seq_str then
      seq = tonumber(seq_str) as integer
    end
    cmd_show(d, seq)
    queue.close(qdb)
    db.close(d)
    return 0

  elseif cmd == "rmm" then
    local seqs: {integer} = {}
    for i = 2, #remaining do
      table.insert(seqs, tonumber(remaining[i]) as integer)
    end
    cmd_rmm(d, seqs)
    queue.close(qdb)
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
      queue.close(qdb)
      db.close(d)
      return 1, "invalid message number: " .. cmd
    end

    local msg = db.get_message_by_seq(d, seq)
    if not msg then
      queue.close(qdb)
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
      queue.close(qdb)
      db.close(d)
      return 0
    end
    prompt = input
    -- Trim trailing newline
    prompt = prompt:gsub("%s+$", "")
    if prompt == "" then
      usage()
      queue.close(qdb)
      db.close(d)
      return 0
    end
  end

  -- Load skills
  local loaded_skills = skills.load_skills()

  -- Expand /skill: invocations first
  local skill_expanded, was_skill = skills.expand_skill(prompt, loaded_skills)
  if was_skill then
    prompt = skill_expanded
  end

  -- Expand commands (prompts starting with /)
  if not was_skill then
    local loaded_commands = commands.load_commands()
    local expanded, was_command = commands.expand_command(prompt, loaded_commands)
    if was_command then
      prompt = expanded
    end
  end

  -- Load system prompt
  local effective_system = load_system_prompt(cwd)

  -- Append skills to system prompt
  local skills_prompt = skills.format_skills_for_prompt(loaded_skills)
  if skills_prompt ~= "" then
    effective_system = effective_system .. "\n\n" .. skills_prompt
  end

  -- Initialize custom tools
  tools.init_custom_tools()

  -- Try to acquire session lock
  local lock_acquired, lock_err = queue.try_acquire_lock(qdb)
  if not lock_acquired then
    -- Session is locked by another process - queue as followup
    queue.add_followup(qdb, prompt)
    io.stderr:write("session locked, queued as followup: " .. (lock_err or "") .. "\n")
    queue.close(qdb)
    db.close(d)
    return 0
  end

  -- Install SIGINT handler for graceful Ctrl+C with abort cascade:
  -- 1. Set interrupted flag (checked by loop between iterations and mid-stream)
  -- 2. Immediately abort any running tool processes (SIGTERM -> SIGKILL)
  -- 3. Release session lock
  unix.sigaction(unix.SIGINT, function()
    interrupted = true
    tools.abort_running_tools()
    queue.release_lock(qdb)
  end)

  -- Resolve model alias
  local effective_model = api.resolve_model(model)

  -- Run agent with CLI event handler
  local on_event = make_cli_handler()
  loop.run_agent(d, qdb, effective_system, effective_model, prompt, parent_id, on_event)

  -- Mark session as closed before exit
  db.set_session_state(d, "closed")

  -- Release lock and clean up
  queue.release_lock(qdb)
  queue.close(qdb)
  db.close(d)
  return 0
end

return {
  main = main,
  load_system_prompt = load_system_prompt,
  load_claude_md = load_claude_md,
  make_cli_handler = make_cli_handler,
  tool_key_param = loop.tool_key_param,
  list_sessions = list_sessions,
  resolve_session = resolve_session,
}
