-- ah/limits.tl: Claude Max subscription usage display
local fetch = require("cosmic.fetch")
local json = require("cosmic.json")
local auth = require("ah.auth")
local util = require("ah.util")

-- Detect proxy from environment (same pattern as api.tl).
local function get_proxy_url(): string
  local http_proxy = os.getenv("https_proxy") or os.getenv("HTTPS_PROXY")
  or os.getenv("http_proxy") or os.getenv("HTTP_PROXY")
  if http_proxy and http_proxy:sub(1, 7) == "unix://" then
    local path = http_proxy:sub(8)
    local url, err = fetch.unix_proxy(path)
    if url then
      return url
    else
      util.debug("[limits] warning: invalid proxy url: " .. (err or "unknown"))
    end
  end
  return nil
end

-- Format a number with comma separators.
local function fmt_num(n: number): string
  if not n then return "?" end
  local s = tostring(math.floor(n))
  -- Insert commas every three digits from the right.
  local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  -- Remove leading comma if length is a multiple of 3.
  result = result:gsub("^,", "")
  return result
end

-- Format a usage window line.
local function fmt_window(label: string, used: number, limit: number): string
  if not used or not limit then
    return string.format("  %-12s  unknown", label)
  end
  local pct = limit > 0 and math.floor(used * 100 / limit) or 0
  return string.format("  %-12s  %d%% (%s / %s)",
    label, pct, fmt_num(used), fmt_num(limit))
end

-- Read the full body from a fetch reader.
local function read_body(reader: fetch.Reader): string
  local parts: {string} = {}
  while true do
    local chunk = reader:read()
    if not chunk or chunk == "" then break end
    table.insert(parts, chunk)
  end
  reader:close()
  return table.concat(parts)
end

-- Fetch and display Claude Max subscription usage.
local function cmd_limits(): integer
  local creds, err = auth.load_credentials()
  if not creds then
    util.log("limits: " .. (err or "no credentials"))
    return 1
  end
  if not creds.is_oauth then
    util.log("limits: requires OAuth auth (set CLAUDE_CODE_OAUTH_TOKEN)")
    return 1
  end

  local url = "https://api.anthropic.com/api/oauth/usage"
  local result = fetch.stream(url, {
      method = "GET",
      headers = {
        ["authorization"] = "Bearer " .. creds.access_token,
        ["accept"] = "application/json",
      } as {string: string},
      proxy = get_proxy_url(),
    } as fetch.Opts)

  if not result.ok then
    util.log("limits: fetch failed: " .. (result.error or "unknown"))
    return 1
  end

  local body = read_body(result.reader)

  if result.status ~= 200 then
    util.log(string.format("limits: API error %s: %s", tostring(result.status), body))
    return 1
  end

  local data = json.decode(body) as {string: any}
  if not data then
    util.log("limits: could not parse response")
    return 1
  end

  -- The response shape is not officially documented; access defensively.
  -- Expected structure (based on community findings):
  --   { "5h": { "used": N, "limit": N }, "7d": { "used": N, "limit": N } }
  local w5h = data["5h"] as {string: number}
  local w7d = data["7d"] as {string: number}

  io.write("claude max usage:\n")

  if w5h then
    io.write(fmt_window("5h window:", w5h.used, w5h.limit) .. "\n")
  else
    io.write("  5h window:    unavailable\n")
  end

  if w7d then
    io.write(fmt_window("7d window:", w7d.used, w7d.limit) .. "\n")
  else
    io.write("  7d window:    unavailable\n")
  end

  return 0
end

return {
  cmd_limits = cmd_limits,
  fmt_num = fmt_num,
  fmt_window = fmt_window,
}
