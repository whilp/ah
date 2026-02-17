-- ah/highlight.tl: diff syntax highlighting for terminal output
local record M
  colorize_diff: function(text: string, enabled: boolean): string
end

local GREEN = "\27[32m"
local RED = "\27[31m"
local CYAN = "\27[36m"
local RESET = "\27[0m"

-- colorize_diff detects ```diff fences in text and applies ANSI colors
-- to diff lines within them. only active when enabled is true.
M.colorize_diff = function(text: string, enabled: boolean): string
  if not enabled or not text or text == "" then
    return text or ""
  end

  -- quick check: skip work if no diff fence present
  if not text:find("```diff", 1, true) then
    return text
  end

  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  -- remove trailing empty line added by the gmatch trick
  if #lines > 0 and lines[#lines] == "" and not text:match("\n$") then
    table.remove(lines)
  end

  local in_diff = false
  local result: {string} = {}

  for _, line in ipairs(lines) do
    if not in_diff then
      if line:match("^```diff") then
        in_diff = true
        table.insert(result, line)
      else
        table.insert(result, line)
      end
    else
      -- check for closing fence
      if line:match("^```$") or (line:match("^```") and not line:match("^```diff")) then
        in_diff = false
        table.insert(result, line)
      elseif line:match("^@@") then
        table.insert(result, CYAN .. line .. RESET)
      elseif line:match("^%+") then
        table.insert(result, GREEN .. line .. RESET)
      elseif line:match("^%-") then
        table.insert(result, RED .. line .. RESET)
      else
        table.insert(result, line)
      end
    end
  end

  return table.concat(result, "\n") .. (text:match("\n$") and "\n" or "")
end

return M
