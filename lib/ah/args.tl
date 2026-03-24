-- ah/args.tl: CLI argument parsing
local getopt = require("cosmic.getopt")
local cio = require("cosmic.io")
local api = require("ah.api")

local record ParsedArgs
  model: string
  db_path: string
  output_path: string
  new_session: boolean
  session_prefix: string
  session_name: string
  steer_msg: string
  followup_msg: string
  max_session_tokens: integer
  max_turn_tokens: integer
  sandbox: boolean
  timeout: integer
  allow_hosts: {string}
  unveil_dirs: {string}
  pledge_promises: string
  skill: string
  must_produce: string
  tool_overrides: {string}
  cd_path: string
  remaining: {string}
end

local function usage_text(): string
  local parts: {string} = {}

  -- Load base help text from embedded file
  local base_help = cio.slurp("/zip/embed/sys/help.md") or ""

  table.insert(parts, base_help)

  -- Append dynamic model aliases
  for alias, full in pairs(api.MODEL_ALIASES) do
    table.insert(parts, string.format("  %-18s  %s\n", alias, full))
  end
  return table.concat(parts)
end

local function usage()
  io.stderr:write(usage_text())
end

-- Parse colon-separated protect dirs from AH_PROTECT_DIRS env var
local function parse_protect_dirs(s: string): {string}
  local dirs: {string} = {}
  if not s or s == "" then return dirs end
  for dir in s:gmatch("[^:]+") do
    table.insert(dirs, dir)
  end
  return dirs
end

-- Parse "path:perms" from --unveil value. Strips suffix, default to read-only
local function parse_unveil_entry(entry: string): string, string
  local path, perms = entry:match("^(.+):([rwxc]+)$")
  if path and perms then
    return path, perms
  end
  -- No perms suffix, default to read-only
  return entry, "r"
end

local function parse_args(args: {string}): ParsedArgs, string
  local result: ParsedArgs = {
    new_session = false,
    sandbox = false,
    allow_hosts = {},
    unveil_dirs = {},
    tool_overrides = {},
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
    {name = "max-session-tokens", has_arg = "required"},
    {name = "max-turn-tokens", has_arg = "required"},
    {name = "sandbox", has_arg = "none"},
    {name = "timeout", has_arg = "required"},
    {name = "allow-host", has_arg = "required"},
    {name = "unveil", has_arg = "required"},
    {name = "pledge", has_arg = "required"},
    {name = "skill", has_arg = "required"},
    {name = "must-produce", has_arg = "required"},
    {name = "tool", has_arg = "required", short = "t"},
    {name = "cd", has_arg = "required"},
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
      result.max_session_tokens = tonumber(optarg) as integer
    elseif opt == "max-session-tokens" then
      result.max_session_tokens = tonumber(optarg) as integer
    elseif opt == "max-turn-tokens" then
      result.max_turn_tokens = tonumber(optarg) as integer
    elseif opt == "sandbox" then
      result.sandbox = true
    elseif opt == "timeout" then
      result.timeout = tonumber(optarg) as integer
    elseif opt == "allow-host" then
      table.insert(result.allow_hosts, optarg)
    elseif opt == "unveil" then
      table.insert(result.unveil_dirs, optarg)
    elseif opt == "pledge" then
      result.pledge_promises = optarg
    elseif opt == "skill" then
      result.skill = optarg
    elseif opt == "must-produce" then
      result.must_produce = optarg
    elseif opt == "t" or opt == "tool" then
      table.insert(result.tool_overrides, optarg)
    elseif opt == "cd" then
      result.cd_path = optarg
    elseif opt == "?" then
      return nil, "unknown"
    end
  end

  result.remaining = parser:remaining() or {}

  return result, nil
end

-- OptionArgType indicates whether an option requires an argument
local enum OptionArgType
  "required"
  "none"
end

-- OptionDef describes a command-line option
local record OptionDef
  name: string -- long name (e.g. "output")
  short: string -- short name (e.g. "o")
  has_arg: OptionArgType
end

-- parse_subcommand_options scans args for options defined in opts.
-- Returns a table mapping option names to their values (nil if not present).
-- Supports -s val, -sval, --name val forms. Last occurrence wins.
-- This allows parsing options that appear after a subcommand.
local function parse_subcommand_options(args: {string}, opts: {OptionDef}): {string: string}
  local result: {string: string} = {}

  -- Build optstring for getopt
  local optstring_parts: {string} = {}
  local opt_map: {string: string} = {} -- maps short letter to long name

  for _, opt in ipairs(opts) do
    optstring_parts[#optstring_parts + 1] = opt.short
    if opt.has_arg == "required" then
      optstring_parts[#optstring_parts + 1] = ":"
    end
    opt_map[opt.short] = opt.name
  end

  local optstring = table.concat(optstring_parts)
  -- Convert OptionDef to the format expected by getopt
  local longopts: {getopt.LongOpt} = {}
  for i, opt in ipairs(opts) do
    longopts[i] = {
      name = opt.name,
      has_arg = opt.has_arg,
      short = opt.short
    }
  end
  local parser = getopt.new(args, optstring, longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end

    -- Map short option letters to long names
    local name = opt_map[opt] or opt

    if optarg then
      result[name] = optarg
    else
      result[name] = "true"
    end
  end

  return result
end

return {
  ParsedArgs = ParsedArgs,
  OptionArgType = OptionArgType,
  OptionDef = OptionDef,
  parse_args = parse_args,
  parse_subcommand_options = parse_subcommand_options,
  parse_protect_dirs = parse_protect_dirs,
  parse_unveil_entry = parse_unveil_entry,
  usage_text = usage_text,
  usage = usage,
}
