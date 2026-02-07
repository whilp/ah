-- ah/auth.lua: OAuth/API key credential loading
local fs = require("cosmic.fs")
local io = require("cosmic.io")
local json = require("cosmic.json")

local record Credentials
  access_token: string
  refresh_token: string
  expires_at: string
  is_api_key: boolean
end

local function parse_env_file(path: string): {string:string}
  local content = io.slurp(path)
  if not content then
    return nil
  end
  local env: {string:string} = {}
  for line in content:gmatch("[^\n]+") do
    if not line:match("^%s*#") and not line:match("^%s*$") then
      local key, value = line:match("^([%w_]+)=(.*)$")
      if key and value then
        value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
        env[key] = value
      end
    end
  end
  return env
end

local function load_credentials(): Credentials, string
  -- 1. Check for API key first (most reliable)
  local api_key = os.getenv("ANTHROPIC_API_KEY")
  if api_key then
    return {access_token = api_key, is_api_key = true}
  end

  -- 2. Check env var (Claude Code OAuth token)
  local token = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
  if token then
    return {access_token = token}
  end

  -- 3. Read .env file if present
  local env = parse_env_file(".env")
  if env and env.ANTHROPIC_API_KEY then
    return {access_token = env.ANTHROPIC_API_KEY, is_api_key = true}
  end

  -- 4. Read ~/.claude/.credentials.json
  local home = os.getenv("HOME")
  if home then
    local cred_path = fs.join(home, ".claude", ".credentials.json")
    local content = io.slurp(cred_path)
    if content then
      local creds = json.decode(content) as Credentials
      if creds and creds.access_token then
        return creds
      end
    end
  end

  return nil, "no credentials found (set ANTHROPIC_API_KEY)"
end

local function get_auth_headers(creds: Credentials): {string:string}
  local headers: {string:string} = {
    ["anthropic-version"] = "2023-06-01",
    ["content-type"] = "application/json",
  }

  if creds.is_api_key then
    headers["x-api-key"] = creds.access_token
  else
    headers["Authorization"] = "Bearer " .. creds.access_token
  end

  return headers
end

return {
  Credentials = Credentials,
  load_credentials = load_credentials,
  get_auth_headers = get_auth_headers,
}
