-- ah/sessions.tl: session listing, resolution, and usage display
local fs = require("cosmic.fs")
local db = require("ah.db")
local ulid = require("ulid")
local cli = require("ah.cli")

-- Session record for listing
local record Session
  ulid: string
  db_path: string
  msg_count: integer
  first_prompt: string
  timestamp: number
  name: string
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
      local session_ulid = name:sub(1, -4) -- remove .db
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
      local detail = json.decode(e.details) as {string: any}
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
  io.write(string.format("input:         %s\n", cli.format_tokens(total_input)))
  io.write(string.format("output:        %s\n", cli.format_tokens(total_output)))
  io.write(string.format("total:         %s\n", cli.format_tokens(total)))
  io.write(string.format("cache read:    %s\n", cli.format_tokens(total_cache_read)))
  io.write(string.format("cache write:   %s\n", cli.format_tokens(total_cache_create)))
  if total_input > 0 then
    local cache_pct = math.floor(total_cache_read * 100 / total_input)
    io.write(string.format("cache hit:     %d%%\n", cache_pct))
  end

  -- Per-call breakdown
  if #calls > 0 then
    io.write("\ncalls:\n")
    for i, c in ipairs(calls) do
      io.write(string.format("  #%-3d +%-6s in  +%-6s out  %4dms  %s\n",
          i, cli.format_tokens(c.input), cli.format_tokens(c.output),
          c.latency, short_model(c.model)))
    end
  end
end

return {
  Session = Session,
  list_sessions = list_sessions,
  resolve_session = resolve_session,
  cmd_sessions = cmd_sessions,
  cmd_usage = cmd_usage,
  short_model = short_model,
}
