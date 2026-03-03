-- sys/tools/protect.tl: shared path protection check for AH_PROTECT_DIRS
local fs = require("cosmic.fs")

local function is_protected(path: string): boolean
  local protect_env = os.getenv("AH_PROTECT_DIRS") or ""
  if protect_env == "" then return false end
  local cwd = fs.getcwd() or ""
  local abs_path: string
  if path:sub(1, 1) == "/" then
    abs_path = path
  else
    abs_path = cwd .. "/" .. path
  end
  for dir in protect_env:gmatch("[^:]+") do
    local abs_dir: string
    if dir:sub(1, 1) == "/" then
      abs_dir = dir
    else
      abs_dir = cwd .. "/" .. dir
    end
    if abs_path == abs_dir or abs_path:sub(1, #abs_dir + 1) == abs_dir .. "/" then
      return true
    end
  end
  return false
end

return { is_protected = is_protected }
