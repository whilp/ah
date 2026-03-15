-- ah/util.tl: logging utilities with level support
local fetch = require("cosmic.fetch")
local cenv = require("cosmic.env")

local record M
  log_level: string
  log: function(msg: string)
  debug: function(msg: string)
  get_proxy_url: function(): string
end

-- Determine default log level: "info" when CI is set, "debug" otherwise
local env_level = cenv.get("AH_LOG_LEVEL")
if env_level then
  M.log_level = env_level
elseif cenv.get("CI") then
  M.log_level = "info"
else
  M.log_level = "debug"
end

M.log = function(msg: string)
  io.stderr:write(msg .. "\n")
end

M.debug = function(msg: string)
  if M.log_level == "debug" then
    io.stderr:write(msg .. "\n")
  end
end

-- Detect proxy from environment (set by work.tl for sandboxed processes).
-- Resolved lazily so envd.load() has time to set vars before first use.
M.get_proxy_url = function(): string
  local http_proxy = cenv.get("https_proxy") or cenv.get("HTTPS_PROXY")
  or cenv.get("http_proxy") or cenv.get("HTTP_PROXY")
  if http_proxy and http_proxy:sub(1, 7) == "unix://" then
    local path = http_proxy:sub(8)
    local url, err = fetch.unix_proxy(path)
    if url then
      return url
    else
      M.debug("[proxy] warning: invalid proxy url: " .. (err or "unknown"))
    end
  end
  return nil
end

return M
