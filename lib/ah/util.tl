-- ah/util.tl: logging utilities with level support
local record M
  log_level: string
  log: function(msg: string)
  debug: function(msg: string)
end

-- Determine default log level: "info" when CI is set, "debug" otherwise
local env_level = os.getenv("AH_LOG_LEVEL")
if env_level then
  M.log_level = env_level
elseif os.getenv("CI") then
  M.log_level = "info"
else
  M.log_level = "debug"
end

function M.log(msg: string)
  io.stderr:write(msg .. "\n")
end

function M.debug(msg: string)
  if M.log_level == "debug" then
    io.stderr:write(msg .. "\n")
  end
end

return M
