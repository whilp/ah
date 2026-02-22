-- ah/auth.lua: API key credential loading
local io = require("cosmic.io")

local record Credentials
  access_token: string
  is_oauth: boolean
  is_bearer: boolean
end

local function parse_env_file(path: string): {string: string}
  local content = io.slurp(path)
  if not content then
    return nil
  end
  local env: {string: string} = {}
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

-- Strip leading/trailing whitespace and control characters from a token.
-- Tokens from environment variables or .env files may contain trailing
-- newlines or carriage returns that are invalid in HTTP header values.
local function sanitize_token(token: string): string
  if not token then return nil end
  return (token:match("^%s*(.-)%s*$"))
end

local function load_credentials(): Credentials, string
  -- Priority: CLAUDE_CODE_OAUTH_TOKEN (OAuth tokens for Claude Max)
  local oauth_token = sanitize_token(os.getenv("CLAUDE_CODE_OAUTH_TOKEN"))
  if oauth_token and oauth_token ~= "" then
    return {access_token = oauth_token, is_oauth = true}
  end

  -- ANTHROPIC_AUTH_TOKEN: Bearer token (e.g. proxy or custom endpoint)
  local auth_token = sanitize_token(os.getenv("ANTHROPIC_AUTH_TOKEN"))
  if auth_token and auth_token ~= "" then
    return {access_token = auth_token, is_oauth = false, is_bearer = true}
  end

  -- Fall back to ANTHROPIC_API_KEY (regular API key)
  local api_key = sanitize_token(os.getenv("ANTHROPIC_API_KEY"))
  if api_key and api_key ~= "" then
    return {access_token = api_key, is_oauth = false}
  end

  local env = parse_env_file(".env")
  if env and env.ANTHROPIC_API_KEY then
    local key = sanitize_token(env.ANTHROPIC_API_KEY)
    if key and key ~= "" then
      return {access_token = key, is_oauth = false}
    end
  end

  return nil, "no credentials found (set ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or CLAUDE_CODE_OAUTH_TOKEN)"
end

local function get_auth_headers(creds: Credentials): {string: string}
  if creds.is_oauth then
    -- OAuth-specific headers for Claude Max (mimics Claude Code)
    return {
      ["accept"] = "application/json",
      ["anthropic-version"] = "2023-06-01",
      ["anthropic-beta"] = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
      ["anthropic-dangerous-direct-browser-access"] = "true",
      ["authorization"] = "Bearer " .. creds.access_token,
      ["content-type"] = "application/json",
      ["user-agent"] = "claude-cli/2.1.2 (external, cli)",
      ["x-app"] = "cli",
    }
  end

  -- Bearer token without Claude Code identity headers
  if creds.is_bearer then
    return {
      ["anthropic-version"] = "2023-06-01",
      ["content-type"] = "application/json",
      ["authorization"] = "Bearer " .. creds.access_token,
    }
  end

  -- Regular API key headers
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
