-- ah/spinner.tl: braille spinner for thinking indicator
local child = require("cosmic.child")
local unix = require("cosmo.unix")

local FRAMES = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local INTERVAL_NS = 80000000  -- 80ms in nanoseconds

local record Spinner
  pid: number
  msg_len: integer
end

-- Start spinner in forked child process (only if stderr is a tty)
-- Optional message is displayed after the spinner
local function start(msg?: string): Spinner
  -- Skip spinner if not interactive
  if not unix.isatty(2) then
    return {pid = 0, msg_len = 0}
  end

  msg = msg or ""
  local display = msg ~= "" and (" " .. msg) or ""
  local clear_len = #display + 2  -- spinner char + space + message

  local pid = child.fork()
  if pid == 0 then
    -- Child process: animate spinner
    local i = 1
    while true do
      io.stderr:write("\r" .. FRAMES[i] .. display)
      io.stderr:flush()
      unix.nanosleep(0, INTERVAL_NS)
      i = (i % #FRAMES) + 1
    end
  end
  -- Parent: return handle
  return {pid = pid, msg_len = clear_len}
end

-- Stop spinner and clear line
local function stop(s: Spinner)
  if s and s.pid and s.pid > 0 then
    child.kill(s.pid, child.SIGKILL)
    child.wait(s.pid)
    -- Clear spinner and message from line
    local spaces = string.rep(" ", (s.msg_len or 2) as integer)
    io.stderr:write("\r" .. spaces .. "\r")
    io.stderr:flush()
  end
end

return {
  start = start,
  stop = stop,
  Spinner = Spinner,
}
