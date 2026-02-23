-- ah/util.tl: logging utilities with level support
-- Log levels (from most to least verbose): debug > warn > info
local record M
  log_level: string
  log: function(msg: string)
  warn: function(msg: string)
  debug: function(msg: string)
end

-- Determine default log level: "info" when CI is set, "warn" otherwise
-- Levels: "debug" (most verbose) > "warn" > "info" (least verbose)
local env_level = os.getenv("AH_LOG_LEVEL")
if env_level then
  M.log_level = env_level
elseif os.getenv("CI") then
  M.log_level = "info"
else
  M.log_level = "warn"
end

M.log = function(msg: string)
  io.stderr:write(msg .. "\n")
end

M.warn = function(msg: string)
  if M.log_level == "debug" or M.log_level == "warn" then
    io.stderr:write(msg .. "\n")
  end
end

M.debug = function(msg: string)
  if M.log_level == "debug" then
    io.stderr:write(msg .. "\n")
  end
end

return M
