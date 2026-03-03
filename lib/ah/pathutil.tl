-- lib/ah/pathutil.tl: shared path utilities
local fs = require("cosmic.fs")

local M = {}

M.warn_if_outside_cwd = function(path: string, tool: string)
  if path:sub(1, 1) ~= "/" then return end
  local cwd = fs.getcwd() or ""
  if cwd == "" then return end
  local norm_path = fs.realpath(path) or path
  local norm_cwd = fs.realpath(cwd) or cwd
  if norm_path ~= norm_cwd and norm_path:sub(1, #norm_cwd + 1) ~= norm_cwd .. "/" then
    io.stderr:write("warning: " .. tool .. " target is outside working directory: " .. path .. "\n")
  end
end

return M
