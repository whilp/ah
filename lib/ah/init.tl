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
local util = require("ah.util")
local envd = require("cosmic.envd")
local render = require("ah.render")

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
local function load_system_prompt(cwd: string, extra_agents?: {string}): string
  cwd = cwd or fs.getcwd()
  local claude_md = load_claude_md(cwd)

  if extra_agents then
    for _, path in ipairs(extra_agents) do
      local content = cio.slurp(path)
      if content then
        claude_md = claude_md .. "\n\n# Agent Context\n\n" .. content
      end
    end
  end

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
  sessions            list all sessions
  usage               show token usage and cache stats
  embed <dir>         embed files into /zip/embed/
  extract <dir>       extract /zip/embed/ to directory

options:
  -h, --help          show this help
  -V, --version       show version and exit
  -n, --new           start a new session
  -S, --session ULID  use specific session (prefix match)
  --name NAME         set or match session by name
  --db PATH           use custom database path (default: .ah/<ulid>.db)
  -m, --model MODEL   set model (default: opus, or AH_MODEL env)
  -o, --output FILE   output file (used with embed)
  --steer MSG         send steering message to running session
  --followup MSG      queue followup message for after session completes
  --max-tokens N      stop when cumulative tokens exceed N
  --skill NAME        invoke a skill by name (prepends /skill:<name> to prompt)
  --must-produce FILE require the agent to write FILE before finishing
  -t, --tool NAME=CMD register a CLI tool (repeatable, overrides all tiers)
  --agents PATH       load additional agent context file (repeatable)
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

-- Extract short model alias from full model name
local function short_model(name: string): string
  if not name then return "unknown" end
  if name:match("sonnet") then return "sonnet"
  elseif name:match("opus") then return "opus"
  elseif name:match("haiku") then return "haiku"
  else return name
  end
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

  local record CallInfo
    input: integer
    output: integer
    latency: integer
    model: string
  end
  local calls: {CallInfo} = {}

  for _, e in ipairs(ev) do
    if e.details then
      local detail = json.decode(e.details) as {string:any}
      if detail then
        local inp = (detail.input_tokens or 0) as integer
        local out = (detail.output_tokens or 0) as integer
        local lat = (detail.api_latency_ms or 0) as integer
        local mdl = (detail.model or "unknown") as string
        total_input = total_input + inp
        total_output = total_output + out
        total_cache_read = total_cache_read + ((detail.cache_read_input_tokens or 0) as integer)
        total_cache_create = total_cache_create + ((detail.cache_creation_input_tokens or 0) as integer)
        api_calls = api_calls + 1
        table.insert(calls, {input = inp, output = out, latency = lat, model = mdl})
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

  -- Per-call breakdown
  if #calls > 0 then
    io.write("\ncalls:\n")
    for i, c in ipairs(calls) do
      io.write(string.format("  #%-3d +%-6s in  +%-6s out  %4dms  %s\n",
        i, format_tokens(c.input), format_tokens(c.output),
        c.latency, short_model(c.model)))
    end
  end
end

-- Colorize a single diff line with ANSI escape codes.
-- Uses blue/yellow instead of green/red for colorblind accessibility.
-- Returns the line with color prefix/suffix applied, or unchanged if not a diff line.
local function colorize_diff_line(line: string): string
  if line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" then
    return "\27[1m" .. line .. "\27[0m"
  elseif line:sub(1, 2) == "@@" then
    return "\27[36m" .. line .. "\27[0m"
  elseif line:sub(1, 1) == "+" then
    return "\27[34m" .. line .. "\27[0m"
  elseif line:sub(1, 1) == "-" then
    return "\27[33m" .. line .. "\27[0m"
  end
  return line
end

-- Colorize a single tool output line with ANSI escape codes.
-- Uses blue+bold for success (PASS) and yellow+bold for errors (FAIL, error, exit code).
-- Uses blue/yellow instead of green/red for colorblind accessibility.
-- Returns the line (possibly colored) and a boolean indicating if color was applied.
local function colorize_tool_line(line: string): string, boolean
  if line:sub(1, 4) == "PASS" then
    return "\27[1;34m" .. line .. "\27[0m", true
  elseif line:sub(1, 4) == "FAIL" then
    return "\27[1;33m" .. line .. "\27[0m", true
  elseif line:sub(1, 6) == "error:" or line:sub(1, 6) == "Error:" then
    return "\27[1;33m" .. line .. "\27[0m", true
  elseif line:sub(1, 10) == "exit code:" then
    return "\27[1;33m" .. line .. "\27[0m", true
  end
  return line, false
end

-- CLI display handler: renders structured events to stderr/stdout for terminal use.
-- This is the application-layer implementation of the event callback.
-- Other handlers (JSON logging, web UI, etc.) can be substituted.
local function make_cli_handler(skill_name: string): events.EventCallback
  local is_tty = tty.isatty(2)
  local is_stdout_tty = tty.isatty(1)
  local is_ci = os.getenv("GITHUB_ACTIONS") == "true"
  local DIM = is_tty and "\27[2m" or ""
  local RESET = is_tty and "\27[0m" or ""
  local has_text = false
  local text_buffer: {string} = {}


  -- Flush buffered agent response text to stdout
  local function flush_text()
    if #text_buffer > 0 then
      local text = table.concat(text_buffer)
      if is_stdout_tty then
        text = render.render_markdown(text)
      end
      io.write(text)
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
      local cache_read = event.total_cache_read_tokens or 0
      if total_in > 0 or total_out > 0 then
        io.stderr:write("\n")
        local in_str = format_tokens(total_in)
        if cache_read > 0 then
          in_str = in_str .. " (" .. format_tokens(cache_read) .. " cached)"
        end
        io.stderr:write(string.format("%s%s in / %s out (%s total)%s\n", DIM, in_str, format_tokens(total_out), format_tokens(total_in + total_out), RESET))
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
      local indent = "  "
      local elapsed = (event.duration_ms or 0) / 1000

      -- Line 1: tool name and timing
      -- Use yellow+bold with ✗ prefix for errors, dim with ⠋ for success
      if is_tty and event.is_error then
        io.stderr:write(string.format("\27[1;33m✗ %s (%.1fs)\27[0m\n", event.tool_name, elapsed))
      else
        local prefix = is_tty and "⠋ " or ""
        io.stderr:write(string.format("%s%s%s (%.1fs)%s\n", DIM, prefix, event.tool_name, elapsed, RESET))
      end

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
        -- Detect diff-like commands for colorization
        local is_diff_cmd = false
        if is_tty and event.tool_name == "bash" and key ~= "" then
          is_diff_cmd = key:match("diff") ~= nil
            or key:match("show") ~= nil
            or key:match("log %-p") ~= nil
        end

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
          if is_diff_cmd then
            local colored = colorize_diff_line(line)
            if colored ~= line then
              io.stderr:write(string.format("%s%s%s\n", indent, colored, ""))
            else
              io.stderr:write(string.format("%s%s%s%s\n", DIM, indent, line, RESET))
            end
          elseif is_tty then
            local colored, was_colored = colorize_tool_line(line)
            if was_colored then
              io.stderr:write(string.format("%s%s%s\n", indent, colored, ""))
            else
              io.stderr:write(string.format("%s%s%s%s\n", DIM, indent, line, RESET))
            end
          else
            io.stderr:write(string.format("%s%s%s%s\n", DIM, indent, line, RESET))
          end
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
  tool_overrides: {string}
  agents_files: {string}
  remaining: {string}
end

local function parse_args(args: {string}): ParsedArgs, string
  local result: ParsedArgs = {
    new_session = false,
    sandbox = false,
    allow_hosts = {},
    unveil_dirs = {},
    tool_overrides = {},
    agents_files = {},
    remaining = {},
  }

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "version", has_arg = "none", short = "V"},
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
    {name = "tool", has_arg = "required", short = "t"},
    {name = "agents", has_arg = "required"},
  }

  -- Use + prefix for POSIX mode: stop parsing options at first non-option arg.
  -- This allows subcommands to have their own flags without the top-level
  -- parser rejecting them as unknown options.
  local parser = getopt.new(args, "+hVnS:m:o:t:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end

    if opt == "h" or opt == "help" then
      return nil, "help"
    elseif opt == "V" or opt == "version" then
      return nil, "version"
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
    elseif opt == "t" or opt == "tool" then
      table.insert(result.tool_overrides, optarg)
    elseif opt == "agents" then
      table.insert(result.agents_files, optarg)
    elseif opt == "?" then
      return nil, "unknown"
    end
  end

  result.remaining = parser:remaining() or {}

  -- Validate sandbox sub-options require --sandbox
  if not result.sandbox then
    if #result.unveil_dirs > 0 then
      return nil, "error: --unveil requires --sandbox"
    end
    if #result.allow_hosts > 0 then
      return nil, "error: --allow-host requires --sandbox"
    end
  end

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

local record SandboxMod
  start_sandbox: function(): SandboxCtx, string
  stop_sandbox: function(SandboxCtx)
  prepare_child_stdin: function(): string
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
  -- Load embedded env.d/ variables before anything else.
  -- This allows embedding credentials (API keys, OAuth tokens) into the
  -- executable so they're available for auth and all subsequent logic.
  envd.load()

  -- Enable core dumps for crash debugging
  -- RLIMIT_CORE = 4 on Linux, RLIM_INFINITY = -1
  proc.setrlimit(4, -1, -1)

  -- Sandbox mode: when AH_SANDBOX=1, restrict capabilities
  -- Used by --sandbox flag to run ah with limited network access
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
    if err == "version" then
      local mod = "ah.version"
      local ok, version = pcall(require, mod)
      io.write("ah " .. (ok and version as string or "dev") .. "\n")
      return 0
    end
    if err and err:sub(1, 6) == "error:" then
      io.stderr:write(err .. "\n")
      return 1
    end
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
    local sbox = require("ah.sandbox") as SandboxMod
    local fetch = require("cosmic.fetch") as FetchMod

    local ctx, sbox_err = sbox.start_sandbox()
    if not ctx then
      io.stderr:write("error: sandbox failed to start: " .. (sbox_err or "unknown") .. "\n")
      return 1
    end
    util.debug("[sandbox] proxy started on " .. ctx.socket_path)

    -- Build child environment from raw environ (list of "KEY=VALUE" strings)
    local unix = require("cosmo.unix")
    local run_env: {string} = unix.environ() as {string}
    sbox.setup_git_env(run_env)

    -- Set TMPDIR for APE binary extraction
    sbox.env_set(run_env, "TMPDIR", ctx.tmpdir)

    -- Proxy env vars
    local proxy_url, proxy_err = fetch.unix_proxy(ctx.socket_path)
    if not proxy_url then
      io.stderr:write("[sandbox] invalid proxy path: " .. (proxy_err or "unknown") .. "\n")
      sbox.stop_sandbox(ctx)
      return 1
    end
    sbox.env_set(run_env, "http_proxy", proxy_url)
    sbox.env_set(run_env, "HTTP_PROXY", proxy_url)
    sbox.env_set(run_env, "https_proxy", proxy_url)
    sbox.env_set(run_env, "HTTPS_PROXY", proxy_url)
    sbox.env_set(run_env, "AH_SANDBOX", "1")

    -- Pass allow-host entries to proxy via env
    if #parsed.allow_hosts > 0 then
      sbox.env_set(run_env, "AH_ALLOW_HOSTS", table.concat(parsed.allow_hosts, ","))
    end

    -- Pass unveil entries to child via env
    if #parsed.unveil_dirs > 0 then
      sbox.env_set(run_env, "AH_UNVEIL", table.concat(parsed.unveil_dirs, ","))
    end

    -- Build child argv: strip sandbox-related flags, keep everything else
    local child_args: {string} = {}
    local exe = sbox.ah_exe()

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
    local parent_stdin = sbox.prepare_child_stdin()

    -- Spawn child and wait
    local child_mod = require("cosmic.child") as ChildMod
    util.debug("[sandbox] spawning child: " .. table.concat(child_args, " "))
    util.debug("[sandbox] stdin: " .. (#parent_stdin > 0 and (tostring(#parent_stdin) .. " bytes") or "none"))
    local handle, spawn_err = child_mod.spawn(child_args, {env = run_env, stdin = parent_stdin})
    if not handle then
      io.stderr:write("error: failed to spawn sandboxed child: " .. (spawn_err or "unknown") .. "\n")
      sbox.stop_sandbox(ctx)
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
    util.debug("[sandbox] child exited: " .. tostring(exit_code))
    util.debug("[sandbox] stopping proxy")
    sbox.stop_sandbox(ctx)

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

  end

  -- Handle prompt or continue
  local parent_id: string = nil
  local prompt: string = nil

  prompt = table.concat(remaining, " ")

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
  local active_skill_name: string = parsed.skill
  if parsed.skill then
    prompt = "/skill:" .. parsed.skill .. "\n" .. prompt
  end

  -- Expand /skill: invocations first
  local skill_expanded, was_skill = skills.expand_skill(prompt, loaded_skills)
  if was_skill then
    prompt = skill_expanded
    -- Extract skill name if not already set from --skill flag
    if not active_skill_name then
      active_skill_name = prompt:match('^<skill name="([a-z0-9%-]+)"')
    end
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
  -- Initialize custom tools (must happen before format_tools_for_prompt)
  tools.init_custom_tools(cwd)

  -- Load tools from the active skill's tools/ subdirectory
  if active_skill_name and loaded_skills[active_skill_name] then
    tools.load_skill_tools(loaded_skills[active_skill_name].base_dir)
  end

  -- Apply --tool overrides (highest precedence, overrides everything)
  -- name=cmd adds/replaces a tool; name= (empty cmd) removes it
  for _, spec in ipairs(parsed.tool_overrides) do
    local name, cmd = spec:match("^([^=]+)=(.*)")
    if name and cmd ~= "" then
      tools.add_tool_override(name, cmd)
    elseif name then
      tools.remove_tool(name)
    else
      io.stderr:write("warning: invalid --tool spec (expected name=cmd): " .. spec .. "\n")
    end
  end

  local effective_system = load_system_prompt(cwd, parsed.agents_files)

  -- Append dynamic tool guidance to system prompt
  local tools_prompt = tools.format_tools_for_prompt()
  if tools_prompt ~= "" then
    effective_system = effective_system .. "\n\n" .. tools_prompt
  end

  -- Append skills to system prompt
  local skills_prompt = skills.format_skills_for_prompt(loaded_skills)
  if skills_prompt ~= "" then
    effective_system = effective_system .. "\n\n" .. skills_prompt
  end

  -- Reinforce must-produce in system prompt
  if parsed.must_produce then
    effective_system = effective_system .. "\n\nIMPORTANT: You must write the file `" .. parsed.must_produce .. "` before finishing."
  end

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

  -- Resolve model: --model flag > AH_MODEL env > default
  local effective_model = api.resolve_model(model or os.getenv("AH_MODEL"))

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
  parse_protect_dirs = parse_protect_dirs,
  parse_unveil_entry = parse_unveil_entry,
  usage_text = usage_text,
  colorize_diff_line = colorize_diff_line,
  colorize_tool_line = colorize_tool_line,
}
