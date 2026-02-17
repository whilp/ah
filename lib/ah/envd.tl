-- ah/envd.tl: load environment variables from embedded env.d/ directory
--
-- Each file in /zip/embed/env.d/ sets an environment variable.
-- The filename is the variable name; the file content (trimmed) is the value.
-- Existing environment variables are NOT overwritten.
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local env = require("cosmic.env")
local util = require("ah.util")

-- Load env vars from a directory. Each file's name is the var name,
-- content (trimmed) is the value. Skips files that don't look like
-- valid env var names. Does not overwrite existing env vars.
-- Returns count of variables set.
local function load_env_dir(dir: string): integer
  local dh = fs.opendir(dir)
  if not dh then
    return 0
  end

  local count = 0
  while true do
    local name = dh:read()
    if not name then break end

    -- skip dotfiles and names that aren't valid env var names
    if name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      -- don't overwrite existing env vars
      if not env.get(name) then
        local content = cio.slurp(fs.join(dir, name))
        if content then
          -- trim whitespace (trailing newlines are common)
          local value = content:match("^%s*(.-)%s*$") or ""
          if value ~= "" then
            env.set(name, value)
            count = count + 1
            util.debug("[envd] set " .. name)
          end
        end
      end
    end
  end
  dh:close()

  return count
end

-- Load env.d from embedded archive. Called early in startup.
local function load(): integer
  return load_env_dir("/zip/embed/env.d")
end

return {
  load = load,
  load_env_dir = load_env_dir,
}
