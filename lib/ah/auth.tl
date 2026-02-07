-- ah/auth.lua: API key credential loading
local io = require("cosmic.io")

local record Credentials
  access_token: string
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
  local api_key = os.getenv("ANTHROPIC_API_KEY")
  if api_key then
    return {access_token = api_key}
  end

  local env = parse_env_file(".env")
  if env and env.ANTHROPIC_API_KEY then
    return {access_token = env.ANTHROPIC_API_KEY}
  end

  return nil, "no credentials found (set ANTHROPIC_API_KEY)"
end

local function get_auth_headers(creds: Credentials): {string:string}
  return {
    ["anthropic-version"] = "2023-06-01",
    ["content-type"] = "application/json",
    ["x-api-key"] = creds.access_token,
  }
end

return {
  Credentials = Credentials,
  load_credentials = load_credentials,
  get_auth_headers = get_auth_headers,
}
