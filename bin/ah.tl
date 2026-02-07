#!/usr/bin/env cosmic
-- bin/ah: CLI entry point for ah agent handler
local ah = require("ah")

local code, err = ah.main(arg)
if err then
  io.stderr:write("error: " .. err .. "\n")
end
os.exit(code)
