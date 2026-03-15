#!/usr/bin/env cosmic
-- bin/ah: CLI entry point for ah agent handler
local ah = require("ah")
local proc = require("cosmic.proc")

local code, err = ah.main(arg)
if err then
  io.stderr:write("error: " .. err .. "\n")
end
proc.exit(code)
