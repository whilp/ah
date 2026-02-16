-- ah/init.tl: CLI interface, session management, prompt expansion
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local getopt = require("cosmic.getopt")
local tty = require("cosmic.tty")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")

local zip = require("cosmic.zip")
local embed = require("cosmic.embed")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local commands = require("ah.commands")
local skills = require("ah.skills")
local loop = require("ah.loop")
local events = require("ah.events")
local ulid = require("ulid")
local queue = require("ah.queue")
local sandbox = require("cosmic.sandbox")

-- Session record for listing
local record Session
  ulid: string
  db_path: string
  msg_count: integer
  first_prompt: string
  timestamp: number
  name: string
end

-- Global for signal handling
global interrupted: boolean = false

-- Load CLAUDE.md with embedded base prepended
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()

  -- CLAUDE.md supersedes AGENTS.md when both exist.
  -- Projects should pick one file; CLAUDE.md is the conventional name.
  local project_claude = cio.slurp(fs.join(cwd, "CLAUDE.md"))
  if project_claude then
    return "\n\n# Project Context\n\n" .. project_claude
  end

  local agents_md = cio.slurp(fs.join(cwd, "AGENTS.md"))
  if agents_md then
    return "\n\n# Agent Context\n\n" .. agents_md
  end

  return ""
end

local child = require("cosmic.child")

-- Run a git command in cwd with a 2s timeout. Returns trimmed stdout or nil.
-- Never throws. Any failure (not a repo, git missing, timeout, bad exit) returns nil.
local function git_cmd(cwd: string, ...: string): string
  local argv: {string} = {"timeout", "2", "git"}
  for i = 1, select("#", ...) do
    argv[#argv + 1] = select(i, ...) as string
  end
  local ok, result = pcall(function(): string
    local h, err = child.spawn(argv, {cwd = cwd})
    if not h then return nil end
    local success, stdout, _ = h:read()
    if not success then return nil end
    local out = (stdout as string) or ""
    if out == "" then return nil end
    return (out:gsub("%s+$", ""))
  end)
  if not ok then return nil end
  return result
end

-- Gather git context for the working directory. Each value is nil
-- when the command fails (not a git repo, git not installed, timeout).
local function git_context(cwd: string): {string:string}
  return {
    branch  = git_cmd(cwd, "rev-parse", "--abbrev-ref", "HEAD"),
    commit  = git_cmd(cwd, "rev-parse", "--short", "HEAD"),
    remote  = git_cmd(cwd, "remote", "get-url", "origin"),
  }
end

-- Load system prompt with precedence:
-- 1. /zip/embed/system.md (user override)
-- 2. /zip/embed/sys/system.md (ah default)
-- Project CLAUDE.md and AGENTS.md are always appended
local function load_system_prompt(cwd: string): string
  cwd = cwd or fs.getcwd()
  local claude_md = load_claude_md(cwd)

  local base: string
  local user_system = cio.slurp("/zip/embed/system.md")
  if user_system then
    base = user_system .. claude_md
  else
    local sys_system = cio.slurp("/zip/embed/sys/system.md")
    if sys_system then
      base = sys_system .. claude_md
    else
      base = claude_md
    end
  end

  -- Append runtime context (datetime, working directory, git info)
  local date_str = os.date("!%Y-%m-%dT%H:%M:%SZ") as string
  base = base .. "\n\nCurrent date: " .. date_str .. "\nWorking directory: " .. cwd

  local git = git_context(cwd)
  if git.branch then
    base = base .. "\nGit branch: " .. git.branch
  end
  if git.commit then
    base = base .. "\nGit commit: " .. git.commit
  end
  if git.remote then
    base = base .. "\nGit remote: " .. git.remote
  end

  return base
end

-- List session files from .ah/*.db with valid ULID names
local function list_sessions(cwd?: string): {Session}
  cwd = cwd or fs.getcwd()
  local ah_dir = fs.join(cwd, ".ah")
  local sessions: {Session} = {}

  local dir = fs.opendir(ah_dir)
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
              name = db.get_context(d, "session_name"),
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

-- Resolve session by name or partial ULID prefix
local function resolve_session(cwd: string, prefix: string): string, string
  local sessions = list_sessions(cwd)

  -- First pass: exact name match
  local name_matches: {string} = {}
  for _, s in ipairs(sessions) do
    if s.name and s.name == prefix then
      table.insert(name_matches, s.ulid)
    end
  end

  if #name_matches == 1 then
    return name_matches[1], nil
  elseif #name_matches > 1 then
    return nil, "ambiguous name: " .. prefix .. " matches " .. #name_matches .. " sessions"
  end

  -- Second pass: ULID prefix match
  local matches: {string} = {}

  for _, s in ipairs(sessions) do
    if s.ulid:sub(1, #prefix) == prefix then
      table.insert(matches, s.ulid)
    end
  end

  if #matches == 0 then
    return nil, "no session matches: " .. prefix
  elseif #matches > 1 then
    return nil, "ambiguous prefix: " .. prefix .. " matches " .. #matches .. " sessions"
  end

  return matches[1], nil
end

-- Format token count as human-friendly string (e.g., 1234 -> "1.2k", 12345 -> "12.3k")
local function format_tokens(n: integer): string
  if n >= 1000000 then
    return string.format("%.1fm", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.1fk", n / 1000)
  else
    return tostring(n)
  end
end

local function usage_text(): string
  local parts: {string} = {}
  table.insert(parts, [[usage: ah [options] [command] [args...]

commands:
  <prompt>            send prompt to agent
  (no args)           continue from last message
  @N <prompt>         fork from message N with new prompt
  sessions            list all sessions
  scan                list messages in current branch
  tree                show full conversation tree
  branches            list all branch tips
  diff @A @B          compare two branches
  checkout @N         switch to message N
  branch rm @N        delete branch from message N
  show [N]            show message(s)
  rmm N...            remove messages
  usage               show token usage and cache stats
  work [cmd]          run work loop (plan/do/check/act)
  embed <dir>         embed files into /zip/embed/
  extract <dir>       extract /zip/embed/ to directory

options:
  -h, --help          show this help
  -n, --new           start a new session
  -S, --session ULID  use specific session (prefix match)
  --name NAME         set or match session by name
  --db PATH           use custom database path (default: .ah/<ulid>.db)
  -m, --model MODEL   set model (default: sonnet)
  -o, --output FILE   output file (used with embed)
  --steer MSG         send steering message to running session
  --followup MSG      queue followup message for after session completes
  --max-tokens N      stop when cumulative tokens exceed N
  --skill NAME        invoke a skill by name (prepends /skill:<name> to prompt)
  --must-produce FILE require the agent to write FILE before finishing
  --sandbox           run inside network sandbox (proxy + unveil + pledge)
  --timeout N         wall-clock timeout in seconds
  --allow-host H:P    allow egress to host:port (repeatable, default: api.anthropic.com:443)
  --unveil PATH:PERM  set filesystem visibility (repeatable, perms: r/w/x/c)

models:
]])
  for alias, full in pairs(api.MODEL_ALIASES) do
    table.insert(parts, string.format("  %-18s  %s\n", alias, full))
  end
  return table.concat(parts)
end

local function usage()
  io.stderr:write(usage_text())
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
    local short_ulid = s.ulid:sub(1, 11)
    local name_str = s.name and string.format("  [%s]", s.name) or ""
    local preview = s.first_prompt:gsub("\n", " "):sub(1, 40)
    if #s.first_prompt > 40 then
      preview = preview .. "..."
    end
    io.write(string.format("%s %s  %s  %2d msgs%s  %s\n",
      marker, short_ulid, time_str, s.msg_count, name_str, preview))
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

-- Helper: get message preview text for display
local function msg_preview(d: db.DB, m: db.Message, max_len: integer): string
  max_len = max_len or 50
  local blocks = db.get_content_blocks(d, m.id)
  for _, b in ipairs(blocks) do
    if b.block_type == "text" and b.content and (b.content as string):match("%S") then
      local text = (b.content as string):gsub("\n", " "):sub(1, max_len)
      if #(b.content as string) > max_len then
        text = text .. "..."
      end
      return text
    end
  end
  -- For tool-result-only messages, show tool info
  for _, b in ipairs(blocks) do
    if b.block_type == "tool_use" then
      return "[" .. (b.tool_name or "tool") .. "]"
    elseif b.block_type == "tool_result" then
      return "[tool result]"
    end
  end
  return ""
end

-- Show full conversation tree with all branches
local function cmd_tree(d: db.DB)
  local roots = db.get_root_messages(d)
  if #roots == 0 then
    io.stderr:write("no messages\n")
    return
  end

  local current = db.get_current_message(d)
  local current_id = current and current.id or nil

  -- Build ancestry set for current message to highlight the active branch
  local current_ancestry: {string:boolean} = {}
  if current then
    local ancestors = db.get_ancestry(d, current.id)
    for _, a in ipairs(ancestors) do
      current_ancestry[a.id] = true
    end
  end

  -- Recursive tree printer
  local function print_node(m: db.Message, prefix: string, is_last: boolean, is_root: boolean)
    local role_char = m.role == "user" and "U" or "A"
    local is_current = (m.id == current_id)
    local in_branch = current_ancestry[m.id] or false

    -- Build connector
    local connector = ""
    if is_root then
      connector = ""
    elseif is_last then
      connector = prefix .. "└─ "
    else
      connector = prefix .. "├─ "
    end

    -- Marker: > for current, * for active branch, space otherwise
    local marker = is_current and ">" or (in_branch and "*" or " ")
    local preview = msg_preview(d, m, 50)

    io.write(string.format("%s%s%3d %s: %s\n", connector, marker, m.seq, role_char, preview))

    -- Recurse into children
    local children = db.get_children(d, m.id)
    local child_prefix = ""
    if is_root then
      child_prefix = prefix
    elseif is_last then
      child_prefix = prefix .. "   "
    else
      child_prefix = prefix .. "│  "
    end

    for i, child in ipairs(children) do
      print_node(child, child_prefix, i == #children, false)
    end
  end

  for i, root in ipairs(roots) do
    print_node(root, "", i == #roots, true)
  end
end

-- List all branch tips (leaf messages)
local function cmd_branches(d: db.DB)
  local leaves = db.get_leaf_messages(d)
  if #leaves == 0 then
    io.stderr:write("no branches\n")
    return
  end

  local current = db.get_current_message(d)
  local current_id = current and current.id or nil

  -- For each leaf, find the ancestry to determine if current branch tip contains it
  local current_leaf_id: string = nil
  if current then
    -- Check if current message itself is a leaf
    local current_children = db.get_children(d, current.id)
    if #current_children == 0 then
      current_leaf_id = current.id
    end
  end

  for _, leaf in ipairs(leaves) do
    local marker = (leaf.id == current_leaf_id) and ">" or " "
    local depth = db.get_depth(d, leaf.id)
    local role_char = leaf.role == "user" and "U" or "A"
    local preview = msg_preview(d, leaf, 40)

    io.write(string.format("%s @%-3d %s  depth:%d  %s\n",
      marker, leaf.seq, role_char, depth, preview))
  end
end

-- Switch current message to a specific message (checkout a branch)
local function cmd_checkout(d: db.DB, seq: integer)
  local msg = db.get_message_by_seq(d, seq)
  if not msg then
    io.stderr:write("message not found: @" .. seq .. "\n")
    return
  end
  db.set_current_message(d, msg.id)
  local preview = msg_preview(d, msg, 50)
  io.write(string.format("switched to @%d %s: %s\n", msg.seq, msg.role, preview))
end

-- Delete a branch starting from a message
-- Uses branch-aware resolution: resolve @N in context of current branch
local function cmd_branch_rm(d: db.DB, seq: integer)
  local current = db.get_current_message(d)
  local branch_tip_id = current and current.id or nil
  local msg = db.get_message_by_seq_in_branch(d, seq, branch_tip_id)
  if not msg then
    io.stderr:write("message not found: @" .. seq .. "\n")
    return
  end
  local count = db.delete_branch(d, msg.id)
  io.write(string.format("deleted %d message(s) from @%d\n", count, seq))
end

-- Diff two branch tips: show messages unique to each branch after their common fork point.
-- Accepts two message IDs directly (for programmatic use and disambiguation).
local function cmd_diff(d: db.DB, id_a: string, id_b: string)
  local msg_a = db.get_message(d, id_a)
  if not msg_a then
    io.stderr:write("message not found: " .. id_a .. "\n")
    return
  end
  local msg_b = db.get_message(d, id_b)
  if not msg_b then
    io.stderr:write("message not found: " .. id_b .. "\n")
    return
  end

  -- Build ancestry chains
  local ancestry_a = db.get_ancestry(d, msg_a.id)
  local ancestry_b = db.get_ancestry(d, msg_b.id)

  -- Build id set for branch A's ancestry
  local ids_a: {string:boolean} = {}
  for _, m in ipairs(ancestry_a) do
    ids_a[m.id] = true
  end

  -- Find the deepest common ancestor (last shared message in ancestry order)
  local fork_seq = -1
  for _, m in ipairs(ancestry_b) do
    if ids_a[m.id] then
      fork_seq = m.seq
    end
  end

  -- Collect messages unique to each branch (not in the other's ancestry)
  local ids_b: {string:boolean} = {}
  for _, m in ipairs(ancestry_b) do
    ids_b[m.id] = true
  end

  local only_a: {db.Message} = {}
  for _, m in ipairs(ancestry_a) do
    if not ids_b[m.id] then
      table.insert(only_a, m)
    end
  end

  local only_b: {db.Message} = {}
  for _, m in ipairs(ancestry_b) do
    if not ids_a[m.id] then
      table.insert(only_b, m)
    end
  end

  if #only_a == 0 and #only_b == 0 then
    io.write("no differences (same branch)\n")
    return
  end

  io.write(string.format("fork point: @%d\n\n", fork_seq))

  -- Render a branch section
  local function render_branch(label: string, messages: {db.Message})
    if #messages == 0 then
      io.write(string.format("--- %s: (empty) ---\n", label))
      return
    end
    io.write(string.format("--- %s (%d messages) ---\n", label, #messages))
    for _, m in ipairs(messages) do
      local role_char = m.role == "user" and "U" or "A"
      local blocks = db.get_content_blocks(d, m.id)
      local preview = msg_preview(d, m, 70)
      io.write(string.format("  @%-3d %s: %s\n", m.seq, role_char, preview))

      -- Show tool calls
      for _, b in ipairs(blocks) do
        if b.block_type == "tool_use" then
          local key = loop.tool_key_param(b.tool_name as string, b.tool_input as string, b.details as string)
          if #key > 60 then key = key:sub(1, 57) .. "..." end
          io.write(string.format("         → %s %s\n", b.tool_name, key))
        end
      end
    end
  end

  render_branch(string.format("@%d", msg_a.seq), only_a)
  io.write("\n")
  render_branch(string.format("@%d", msg_b.seq), only_b)
end

-- Token usage summary for a session
local function cmd_usage(d: db.DB)
  local json = require("cosmic.json")
  local ev = db.get_events(d, "api_call_end")

  local total_input = 0
  local total_output = 0
  local total_cache_read = 0
  local total_cache_create = 0
  local api_calls = 0

  for _, e in ipairs(ev) do
    if e.details then
      local detail = json.decode(e.details) as {string:any}
      if detail then
        total_input = total_input + ((detail.input_tokens or 0) as integer)
        total_output = total_output + ((detail.output_tokens or 0) as integer)
        total_cache_read = total_cache_read + ((detail.cache_read_input_tokens or 0) as integer)
        total_cache_create = total_cache_create + ((detail.cache_creation_input_tokens or 0) as integer)
        api_calls = api_calls + 1
      end
    end
  end

  local total = total_input + total_output

  io.write(string.format("api calls:     %d\n", api_calls))
  io.write(string.format("input:         %s\n", format_tokens(total_input)))
  io.write(string.format("output:        %s\n", format_tokens(total_output)))
  io.write(string.format("total:         %s\n", format_tokens(total)))
  io.write(string.format("cache read:    %s\n", format_tokens(total_cache_read)))
  io.write(string.format("cache write:   %s\n", format_tokens(total_cache_create)))
  if total_input > 0 then
    local cache_pct = math.floor(total_cache_read * 100 / total_input)
    io.write(string.format("cache hit:     %d%%\n", cache_pct))
  end
end

-- CLI display handler: renders structured events to stderr/stdout for terminal use.
-- This is the application-layer implementation of the event callback.
-- Other handlers (JSON logging, web UI, etc.) can be substituted.
local function make_cli_handler(skill_name: string): events.EventCallback
  local is_tty = tty.isatty(2)
  local is_ci = os.getenv("GITHUB_ACTIONS") == "true"
  local DIM = is_tty and "\27[2m" or ""
  local RESET = is_tty and "\27[0m" or ""
  local has_text = false
  local text_buffer: {string} = {}

  -- Flush buffered agent response text to stdout
  local function flush_text()
    if #text_buffer > 0 then
      io.write(table.concat(text_buffer))
      io.flush()
      text_buffer = {}
    end
  end

  return function(event: events.EventData)
    local t = event.event_type

    if t == "agent_start" then
      if is_ci and skill_name then
        io.stdout:write("::group::" .. skill_name .. "\n")
        io.stdout:flush()
      end
      -- In non-interactive mode, echo the prompt for clarity
      if not is_tty and event.prompt then
        io.stderr:write(">>> " .. event.prompt .. "\n")
      end

    elseif t == "text_delta" then
      -- Buffer text and print when the response is complete
      table.insert(text_buffer, event.text)
      has_text = true

    elseif t == "agent_end" then
      flush_text()
      -- Trailing newline after text output
      if has_text then
        io.write("\n")
      end
      -- Display session token totals
      local total_in = event.total_input_tokens or 0
      local total_out = event.total_output_tokens or 0
      if total_in > 0 or total_out > 0 then
        io.stderr:write(string.format("%s%s in / %s out (%s total)%s\n", DIM, format_tokens(total_in), format_tokens(total_out), format_tokens(total_in + total_out), RESET))
      end
      if is_ci and skill_name then
        io.stdout:write("::endgroup::\n")
        io.stdout:flush()
      end

    elseif t == "budget_exceeded" then
      local total = (event.total_input_tokens or 0) + (event.total_output_tokens or 0)
      io.stderr:write(string.format("\ntoken budget exceeded (%d/%d tokens)\n", total, event.max_tokens or 0))

    elseif t == "error" then
      local msg = event.error or "unknown"
      io.stderr:write("\nerror: " .. msg .. "\n")
      if is_ci then
        io.stdout:write("::error::" .. msg .. "\n")
        io.stdout:flush()
      end

    elseif t == "api_call_end" then
      -- Flush buffered agent response text now that the response is complete
      flush_text()

    elseif t == "compaction_triggered" then
      io.stderr:write(string.format("\n%scompacting conversation (%d/%d tokens)...%s\n", DIM, event.input_tokens, event.context_limit, RESET))

    elseif t == "compaction_complete" then
      io.stderr:write(string.format("%scompaction complete (summary: %d tokens)%s\n\n", DIM, event.output_tokens, RESET))

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
        if event.tool_name == "bash" then
          local term_width = 80
          local ws = tty.winsize(2)
          if ws then term_width = ws.cols as integer end
          local wrap_indent = indent .. "  "
          key = loop.wrap_command(key, term_width - #indent - #cmd_prefix, wrap_indent)
        end
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

local record ParsedArgs
  model: string
  db_path: string
  output_path: string
  new_session: boolean
  session_prefix: string
  session_name: string
  steer_msg: string
  followup_msg: string
  max_tokens: integer
  sandbox: boolean
  timeout: integer
  allow_hosts: {string}
  unveil_dirs: {string}
  skill: string
  must_produce: string
  remaining: {string}
end

local function parse_args(args: {string}): ParsedArgs, string
  local result: ParsedArgs = {
    new_session = false,
    sandbox = false,
    allow_hosts = {},
    unveil_dirs = {},
    remaining = {},
  }

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "new", has_arg = "none", short = "n"},
    {name = "session", has_arg = "required", short = "S"},
    {name = "name", has_arg = "required"},
    {name = "db", has_arg = "required"},
    {name = "model", has_arg = "required", short = "m"},
    {name = "output", has_arg = "required", short = "o"},
    {name = "steer", has_arg = "required"},
    {name = "followup", has_arg = "required"},
    {name = "max-tokens", has_arg = "required"},
    {name = "sandbox", has_arg = "none"},
    {name = "timeout", has_arg = "required"},
    {name = "allow-host", has_arg = "required"},
    {name = "unveil", has_arg = "required"},
    {name = "skill", has_arg = "required"},
    {name = "must-produce", has_arg = "required"},
  }

  -- Use + prefix for POSIX mode: stop parsing options at first non-option arg.
  -- This allows subcommands like "work" to have their own flags (--repo, --issue,
  -- --prompt) without the top-level parser rejecting them as unknown options.
  local parser = getopt.new(args, "+hnS:m:o:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end

    if opt == "h" or opt == "help" then
      return nil, "help"
    elseif opt == "n" or opt == "new" then
      result.new_session = true
    elseif opt == "S" or opt == "session" then
      result.session_prefix = optarg
    elseif opt == "name" then
      result.session_name = optarg
    elseif opt == "db" then
      result.db_path = optarg
    elseif opt == "m" or opt == "model" then
      result.model = optarg
    elseif opt == "o" or opt == "output" then
      result.output_path = optarg
    elseif opt == "steer" then
      result.steer_msg = optarg
    elseif opt == "followup" then
      result.followup_msg = optarg
    elseif opt == "max-tokens" then
      result.max_tokens = tonumber(optarg) as integer
    elseif opt == "sandbox" then
      result.sandbox = true
    elseif opt == "timeout" then
      result.timeout = tonumber(optarg) as integer
    elseif opt == "allow-host" then
      table.insert(result.allow_hosts, optarg)
    elseif opt == "unveil" then
      table.insert(result.unveil_dirs, optarg)
    elseif opt == "skill" then
      result.skill = optarg
    elseif opt == "must-produce" then
      result.must_produce = optarg
    elseif opt == "?" then
      return nil, "unknown"
    end
  end

  result.remaining = parser:remaining() or {}
  return result
end

-- Parse AH_PROTECT_DIRS env var (colon-separated relative paths).
-- Returns a list of directory paths that should be made read-only via unveil.
local function parse_protect_dirs(value: string): {string}
  local dirs: {string} = {}
  if not value or value == "" then return dirs end
  for dir in value:gmatch("[^:]+") do
    table.insert(dirs, dir)
  end
  return dirs
end

-- Parse an --unveil entry: "path:perms" or just "path" (defaults to "r").
-- Returns path, perms.
local function parse_unveil_entry(entry: string): string, string
  local path, perms = entry:match("^(.+):([rwxc]+)$")
  if path and perms then
    return path, perms
  end
  -- No perms suffix, default to read-only
  return entry, "r"
end

-- Record types for sandbox supervisor mode (lazy-loaded modules)
local record SandboxCtx
  enabled: boolean
  socket_path: string
  proxy_pid: number
  tmpdir: string
end

local record WorkSandboxMod
  start_sandbox: function(): SandboxCtx, string
  stop_sandbox: function(SandboxCtx)
  prepare_child_stdin: function(): string
end

local record WorkUtilMod
  ah_exe: function(): string
  setup_git_env: function({string})
  env_set: function({string}, string, string)
end

local record EnvMod
  all: function(): {string}
end

local record FetchMod
  unix_proxy: function(string): string, string
end

local record ChildMod
  spawn: function({string}, {string:any}): ChildHandle, string
end

local record ChildHandle
  stderr: StderrHandle
  read: function(ChildHandle): boolean, string, string
end

local record StderrHandle
  read: function(StderrHandle): string
end

local function main(args: {string}): integer, string
  -- Enable core dumps for crash debugging
  -- RLIMIT_CORE = 4 on Linux, RLIM_INFINITY = -1
  proc.setrlimit(4, -1, -1)

  -- Sandbox mode: when AH_SANDBOX=1, restrict capabilities
  -- Used by work.tl and --sandbox flag to run ah with limited network access
  if os.getenv("AH_SANDBOX") then
    -- Unveil: restrict filesystem visibility
    local cwd_for_unveil = fs.getcwd()
    sandbox.unveil(cwd_for_unveil, "rwxc")  -- workspace
    -- Protect directories from earlier phases (more specific = higher priority)
    local protect = parse_protect_dirs(os.getenv("AH_PROTECT_DIRS"))
    for _, dir in ipairs(protect) do
      sandbox.unveil(cwd_for_unveil .. "/" .. dir, "r")
    end
    -- Custom unveil entries from AH_UNVEIL (comma-separated path:perms)
    local unveil_env = os.getenv("AH_UNVEIL")
    if unveil_env then
      for entry in unveil_env:gmatch("[^,]+") do
        local u_path, u_perms = parse_unveil_entry(entry)
        if u_path:sub(1, 1) == "/" then
          sandbox.unveil(u_path, u_perms)
        else
          sandbox.unveil(cwd_for_unveil .. "/" .. u_path, u_perms)
        end
      end
    end
    sandbox.unveil("/tmp", "rwxc")           -- proxy socket, temp files, APE binaries
    sandbox.unveil("/usr", "rx")             -- system binaries
    sandbox.unveil("/bin", "rx")             -- system binaries
    sandbox.unveil("/lib", "rx")             -- shared libraries
    sandbox.unveil("/lib64", "rx")           -- shared libraries (64-bit)
    sandbox.unveil("/etc/ssl", "r")          -- CA certificates
    sandbox.unveil("/etc/resolv.conf", "r")  -- DNS config
    sandbox.unveil("/dev/null", "rw")         -- git and other tools need /dev/null
    sandbox.unveil("/dev/tty", "rw")          -- terminal access for interactive tools
    sandbox.unveil("/proc/self", "r")         -- bash and make need /proc/self for process info
    local home = os.getenv("HOME")
    if home then
      sandbox.unveil(home, "r")              -- git/tool configs
    end
    sandbox.unveil(nil, nil)                 -- commit unveil

    -- Pledge: drop inet, keep unix for proxy socket
    -- stdio: basic I/O
    -- rpath/wpath/cpath: file operations
    -- flock: file locking for sqlite
    -- tty: terminal I/O
    -- proc: fork/wait for subprocesses
    -- exec: run git, make, etc.
    -- unix: unix domain sockets (for proxy)
    -- prot_exec: allow mmap(PROT_EXEC) needed by dynamic linker for native binaries
    -- Use EPERM mode (2) so blocked calls return error instead of crashing
    local PLEDGE_PENALTY_RETURN_EPERM = 2
    local promises = "stdio rpath wpath cpath flock tty proc exec execnative unix prot_exec"
    sandbox.pledge(promises, promises, PLEDGE_PENALTY_RETURN_EPERM)
  end

  local cwd = fs.getcwd()

  local parsed, err = parse_args(args)
  if not parsed then
    usage()
    if err == "help" then
      return 0
    end
    return 1
  end

  local model = parsed.model
  local db_path = parsed.db_path
  local output_path = parsed.output_path
  local new_session = parsed.new_session
  local session_prefix = parsed.session_prefix
  local session_name = parsed.session_name
  local steer_msg = parsed.steer_msg
  local followup_msg = parsed.followup_msg
  local max_tokens = parsed.max_tokens
  local remaining = parsed.remaining

  -- Supervisor mode: --sandbox starts proxy, re-execs as sandboxed child
  if parsed.sandbox then
    local work_sandbox = require("ah.work.sandbox") as WorkSandboxMod
    local work_util = require("ah.work.util") as WorkUtilMod
    local env_mod = require("cosmic.env") as EnvMod
    local fetch = require("cosmic.fetch") as FetchMod

    local ctx, sbox_err = work_sandbox.start_sandbox()
    if not ctx then
      io.stderr:write("error: sandbox failed to start: " .. (sbox_err or "unknown") .. "\n")
      return 1
    end
    io.stderr:write("[sandbox] proxy started on " .. ctx.socket_path .. "\n")

    -- Build child environment
    local run_env: {string} = env_mod.all() as {string}
    work_util.setup_git_env(run_env)

    -- Set TMPDIR for APE binary extraction
    work_util.env_set(run_env, "TMPDIR", ctx.tmpdir)

    -- Proxy env vars
    local proxy_url, proxy_err = fetch.unix_proxy(ctx.socket_path)
    if not proxy_url then
      io.stderr:write("[sandbox] invalid proxy path: " .. (proxy_err or "unknown") .. "\n")
      work_sandbox.stop_sandbox(ctx)
      return 1
    end
    work_util.env_set(run_env, "http_proxy", proxy_url)
    work_util.env_set(run_env, "HTTP_PROXY", proxy_url)
    work_util.env_set(run_env, "https_proxy", proxy_url)
    work_util.env_set(run_env, "HTTPS_PROXY", proxy_url)
    work_util.env_set(run_env, "AH_SANDBOX", "1")

    -- Pass allow-host entries to proxy via env
    if #parsed.allow_hosts > 0 then
      work_util.env_set(run_env, "AH_ALLOW_HOSTS", table.concat(parsed.allow_hosts, ","))
    end

    -- Pass unveil entries to child via env
    if #parsed.unveil_dirs > 0 then
      work_util.env_set(run_env, "AH_UNVEIL", table.concat(parsed.unveil_dirs, ","))
    end

    -- Build child argv: strip sandbox-related flags, keep everything else
    local child_args: {string} = {}
    local exe = work_util.ah_exe()

    -- Add timeout wrapper if specified
    if parsed.timeout and parsed.timeout > 0 then
      table.insert(child_args, "timeout")
      table.insert(child_args, tostring(parsed.timeout))
    end

    table.insert(child_args, exe)

    -- Rebuild args without --sandbox, --timeout, --allow-host, --unveil
    local i = 1
    while i <= #args do
      local a = args[i]
      if a == "--sandbox" then
        -- skip
      elseif a == "--timeout" then
        i = i + 1  -- skip value too
      elseif a == "--allow-host" then
        i = i + 1  -- skip value too
      elseif a == "--unveil" then
        i = i + 1  -- skip value too
      else
        table.insert(child_args, a)
      end
      i = i + 1
    end

    -- Read parent stdin before spawning child (stdin may have prompt data)
    local parent_stdin = work_sandbox.prepare_child_stdin()

    -- Spawn child and wait
    local child_mod = require("cosmic.child") as ChildMod
    io.stderr:write("[sandbox] spawning child: " .. table.concat(child_args, " ") .. "\n")
    io.stderr:write("[sandbox] stdin: " .. (#parent_stdin > 0 and (tostring(#parent_stdin) .. " bytes") or "none") .. "\n")
    local handle, spawn_err = child_mod.spawn(child_args, {env = run_env, stdin = parent_stdin})
    if not handle then
      io.stderr:write("error: failed to spawn sandboxed child: " .. (spawn_err or "unknown") .. "\n")
      work_sandbox.stop_sandbox(ctx)
      return 1
    end

    local stderr_out = handle.stderr:read()
    local ok, stdout, exit_str = handle:read()
    local exit_code = (tonumber(exit_str) or 0) as integer

    -- Forward child output
    if stderr_out and stderr_out ~= "" then
      io.stderr:write(stderr_out)
    end
    if stdout and stdout ~= "" then
      io.write(stdout)
    end

    -- Cleanup
    io.stderr:write("[sandbox] child exited: " .. tostring(exit_code) .. "\n")
    io.stderr:write("[sandbox] stopping proxy\n")
    work_sandbox.stop_sandbox(ctx)

    if not ok or exit_code ~= 0 then
      return exit_code ~= 0 and exit_code or 1
    end
    return 0
  end

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
    local tmpdir = fs.mkdtemp("/tmp/ah-embed-XXXXXX")
    local embed_link = fs.join(tmpdir, "embed")
    fs.symlink(fs.realpath(src_dir), embed_link)
    local result = embed.run({tmpdir}, output_path)
    fs.rmrf(tmpdir)
    if result.ok then
      io.write(result.message .. "\n")
      return 0
    else
      io.stderr:write("embed: " .. result.message .. "\n")
      return 1
    end

  elseif cmd == "work" then
    local work = require("ah.work")
    local sub_args: {string} = {}
    for i = 2, #remaining do
      sub_args[#sub_args + 1] = remaining[i]
    end
    return work.main(sub_args)

  elseif cmd == "proxy" then
    -- Internal command: run HTTP CONNECT proxy for sandboxed network access
    local socket_path = remaining[2]
    if not socket_path then
      io.stderr:write("usage: ah proxy <socket-path>\n")
      return 1
    end
    local proxy = require("ah.proxy")
    return proxy.serve(socket_path)

  elseif cmd == "extract" then
    local output_dir = remaining[2]
    if not output_dir then
      io.stderr:write("usage: ah extract <dir>\n")
      return 1
    end
    -- Extract only files from embed/ prefix
    local exe_path = arg[-1]
    local exe_data = cio.slurp(exe_path)
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
          local filepath = fs.join(output_dir, rel_name)
          local dir = fs.dirname(filepath)
          fs.makedirs(dir)
          cio.barf(filepath, content)
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

    if new_session and session_name then
      -- --new + --name: error, conflicting intent
      return 1, "--new and --name cannot be used together"
    elseif session_name then
      -- --name NAME: find existing session by name, or create new
      local sessions = list_sessions(cwd)
      local found: Session = nil
      for _, s in ipairs(sessions) do
        if s.name == session_name then
          if found then
            return 1, "duplicate session name: " .. session_name
          end
          found = s
        end
      end
      if found then
        session_ulid = found.ulid
      else
        session_ulid = ulid.generate()
      end
    elseif new_session then
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

  -- Set session name in context if --name was used on a new session
  if session_name then
    local existing_name = db.get_context(d, "session_name")
    if not existing_name then
      db.set_context(d, "session_name", session_name)
    end
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
  if cmd == "usage" then
    cmd_usage(d)
    queue.close(qdb)
    db.close(d)
    return 0

  elseif cmd == "scan" then
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

  elseif cmd == "tree" then
    cmd_tree(d)
    queue.close(qdb)
    db.close(d)
    return 0

  elseif cmd == "branches" then
    cmd_branches(d)
    queue.close(qdb)
    db.close(d)
    return 0

  elseif cmd == "diff" then
    local a_str = remaining[2]
    local b_str = remaining[3]
    if not a_str or not b_str then
      io.stderr:write("usage: ah diff @A @B\n")
      queue.close(qdb)
      db.close(d)
      return 1
    end
    local a_val = a_str:match("^@?(%d+)$")
    local b_val = b_str:match("^@?(%d+)$")
    if not a_val or not b_val then
      io.stderr:write("invalid message numbers: " .. a_str .. " " .. b_str .. "\n")
      queue.close(qdb)
      db.close(d)
      return 1
    end
    -- Resolve seq numbers to message IDs. When seqs are the same (forked
    -- branches share seq numbers), find distinct messages with that seq
    -- among the leaf messages' ancestries.
    local seq_a = tonumber(a_val) as integer
    local seq_b = tonumber(b_val) as integer
    local leaves = db.get_leaf_messages(d)
    local function resolve_seq_to_id(seq: integer, exclude_id: string): string
      -- Try each leaf's ancestry for a message with the given seq
      for _, leaf in ipairs(leaves) do
        local ancestry = db.get_ancestry(d, leaf.id)
        for _, m in ipairs(ancestry) do
          if m.seq == seq and m.id ~= exclude_id then
            return m.id
          end
        end
      end
      return nil
    end
    local id_a = resolve_seq_to_id(seq_a, nil)
    if not id_a then
      io.stderr:write("message not found: @" .. seq_a .. "\n")
      queue.close(qdb)
      db.close(d)
      return 1
    end
    local id_b = resolve_seq_to_id(seq_b, seq_a == seq_b and id_a or nil)
    if not id_b then
      io.stderr:write("message not found: @" .. seq_b .. "\n")
      queue.close(qdb)
      db.close(d)
      return 1
    end
    cmd_diff(d, id_a, id_b)
    queue.close(qdb)
    db.close(d)
    return 0

  elseif cmd == "checkout" then
    local seq_str = remaining[2]
    if not seq_str then
      io.stderr:write("usage: ah checkout @N\n")
      queue.close(qdb)
      db.close(d)
      return 1
    end
    -- Allow "checkout @3" or "checkout 3"
    local seq_val = seq_str:match("^@?(%d+)$")
    if not seq_val then
      io.stderr:write("invalid message number: " .. seq_str .. "\n")
      queue.close(qdb)
      db.close(d)
      return 1
    end
    cmd_checkout(d, tonumber(seq_val) as integer)
    queue.close(qdb)
    db.close(d)
    return 0

  elseif cmd == "branch" then
    local subcmd = remaining[2]
    if subcmd == "rm" then
      local seq_str = remaining[3]
      if not seq_str then
        io.stderr:write("usage: ah branch rm @N\n")
        queue.close(qdb)
        db.close(d)
        return 1
      end
      local seq_val = seq_str:match("^@?(%d+)$")
      if not seq_val then
        io.stderr:write("invalid message number: " .. seq_str .. "\n")
        queue.close(qdb)
        db.close(d)
        return 1
      end
      cmd_branch_rm(d, tonumber(seq_val) as integer)
    else
      io.stderr:write("usage: ah branch rm @N\n")
    end
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

    -- Use branch-aware seq resolution: prefer messages in current branch
    local current = db.get_current_message(d)
    local branch_tip_id = current and current.id or nil
    local msg = db.get_message_by_seq_in_branch(d, seq, branch_tip_id)
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
    if tty.isatty(0) then
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
    if prompt == "" and not parsed.skill then
      usage()
      queue.close(qdb)
      db.close(d)
      return 0
    end
  end

  -- Load skills
  local loaded_skills = skills.load_skills(cwd)

  -- --skill flag: prepend /skill:<name> to prompt
  if parsed.skill then
    prompt = "/skill:" .. parsed.skill .. "\n" .. prompt
  end

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

  -- Reinforce must-produce in system prompt
  if parsed.must_produce then
    effective_system = effective_system .. "\n\nIMPORTANT: You must write the file `" .. parsed.must_produce .. "` before finishing."
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
  signal.sigaction(signal.SIGINT, function()
    interrupted = true
    tools.abort_running_tools()
    queue.release_lock(qdb)
  end)

  -- Resolve model alias
  local effective_model = api.resolve_model(model)

  -- Run agent with CLI event handler
  local on_event = make_cli_handler(parsed.skill)
  local agent_opts: loop.AgentOpts = {}
  if max_tokens then
    agent_opts.max_tokens = max_tokens
  end
  if parsed.must_produce then
    agent_opts.must_produce = parsed.must_produce
  end
  local stop_reason = loop.run_agent(d, qdb, effective_system, effective_model, prompt, parent_id, on_event, agent_opts)

  -- Mark session as closed before exit
  db.set_session_state(d, "closed")

  -- Release lock and clean up
  queue.release_lock(qdb)
  queue.close(qdb)
  db.close(d)

  -- Return non-zero exit code for error stop reasons
  if stop_reason == "error" then
    return 1
  end

  return 0
end

return {
  main = main,
  parse_args = parse_args,
  load_system_prompt = load_system_prompt,
  load_claude_md = load_claude_md,
  list_sessions = list_sessions,
  resolve_session = resolve_session,
  -- Branch UX commands (exported for testing)
  cmd_tree = cmd_tree,
  cmd_branches = cmd_branches,
  cmd_checkout = cmd_checkout,
  cmd_branch_rm = cmd_branch_rm,
  cmd_diff = cmd_diff,
  parse_protect_dirs = parse_protect_dirs,
  parse_unveil_entry = parse_unveil_entry,
  usage_text = usage_text,
}
