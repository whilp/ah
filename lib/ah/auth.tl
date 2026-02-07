-- ah/auth.lua: OAuth/API key credential loading
local cosmo = require("cosmo")
local path = require("cosmo.path")

local record Credentials
  access_token: string
  refresh_token: string
  expires_at: string
  is_api_key: boolean
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

  -- 3. Read ~/.claude/.credentials.json
  local home = os.getenv("HOME")
  if home then
    local cred_path = path.join(home, ".claude", ".credentials.json")
    local content = cosmo.Slurp(cred_path)
    if content then
      local creds = cosmo.DecodeJson(content) as Credentials
      if creds and creds.access_token then
        return creds
      end
    end
  end

  return nil, "no credentials found (set ANTHROPIC_API_KEY)"
end

local function is_oauth_token(token: string): boolean
  return token:find("sk%-ant%-oat") ~= nil
end

local function get_auth_headers(creds: Credentials): {string:string}
  local headers: {string:string} = {
    ["anthropic-version"] = "2023-06-01",
    ["content-type"] = "application/json",
  }

  if creds.is_api_key then
    headers["x-api-key"] = creds.access_token
  elseif is_oauth_token(creds.access_token) then
    -- Stealth mode: mimic Claude Code headers for OAuth tokens
    headers["Authorization"] = "Bearer " .. creds.access_token
    headers["anthropic-beta"] = "claude-code-20250219,oauth-2025-04-20"
    headers["user-agent"] = "claude-cli/2.1.2 (external, cli)"
    headers["x-app"] = "cli"
  else
    headers["Authorization"] = "Bearer " .. creds.access_token
  end

  return headers
end

local function needs_claude_code_identity(creds: Credentials): boolean
  return not creds.is_api_key and is_oauth_token(creds.access_token)
end

return {
  Credentials = Credentials,
  load_credentials = load_credentials,
  get_auth_headers = get_auth_headers,
  needs_claude_code_identity = needs_claude_code_identity,
}
