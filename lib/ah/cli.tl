-- ah/cli.tl: CLI display handler and output formatting
local tty = require("cosmic.tty")
local events = require("ah.events")
local loop = require("ah.loop")
local render = require("ah.render")
local compact = require("ah.compact")

-- Cache for find_difftool result across calls.
-- false means "already checked, no difftool found"; nil means "not yet checked"
local _difftool_cache: string | boolean = nil

-- Find a difftool for rendering diff output.
-- Checks AH_DIFFTOOL env var first, then autodetects delta on PATH.
-- Returns the tool command string, or nil if none available.
local function find_difftool(): string
  if _difftool_cache ~= nil then
    if _difftool_cache == false then
      return nil
    end
    return _difftool_cache as string
  end

  local env_tool = os.getenv("AH_DIFFTOOL")
  if env_tool and env_tool ~= "" then
    _difftool_cache = env_tool
    return env_tool
  end

  -- Autodetect delta at common paths
  local candidates: {string} = {
    "/usr/bin/delta",
    "/usr/local/bin/delta",
    "/opt/homebrew/bin/delta",
  }
  for _, path in ipairs(candidates) do
    local f = io.open(path, "r")
    if f then
      f:close()
      _difftool_cache = path
      return path
    end
  end

  -- Try PATH via command -v
  local handle = io.popen("command -v delta 2>/dev/null")
  if handle then
    local result = handle:read("*l")
    handle:close()
    if result and result ~= "" then
      _difftool_cache = result
      return result
    end
  end

  _difftool_cache = false
  return nil
end

-- Run diff text through a difftool subprocess.
-- Writes diff_text to a temp file and pipes it to the difftool,
-- avoiding shell quoting issues with Lua's %q format.
-- Returns rendered output string, or nil on failure.
local function run_difftool(difftool: string, diff_text: string): string
  if not difftool or diff_text == "" then
    return nil
  end
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if not f then
    return nil
  end
  f:write(diff_text)
  f:close()
  local handle = io.popen(difftool .. " < " .. tmp .. " 2>/dev/null")
  if not handle then
    os.remove(tmp)
    return nil
  end
  local output = handle:read("*a")
  local ok = handle:close()
  os.remove(tmp)
  if not ok or not output or output == "" then
    return nil
  end
  return output
end

-- Convert the edit tool's pseudo-diff ("- "/"+ " prefixed lines) to unified diff format.
-- Adds --- a/path, +++ b/path, and @@ hunk headers so tools like delta can parse
-- and syntax-highlight the output.
-- Returns nil if the input doesn't look like edit tool output.
local function to_unified_diff(pseudo_diff: string, file_path: string): string
  if not pseudo_diff or pseudo_diff == "" or not file_path or file_path == "" then
    return nil
  end

  local old_count = 0
  local new_count = 0
  local unified_lines: {string} = {}

  for line in pseudo_diff:gmatch("([^\n]*)\n?") do
    if line:sub(1, 2) == "- " then
      old_count = old_count + 1
      table.insert(unified_lines, "-" .. line:sub(3))
    elseif line:sub(1, 2) == "+ " then
      new_count = new_count + 1
      table.insert(unified_lines, "+" .. line:sub(3))
    elseif line ~= "" then
      -- Not a pseudo-diff line; bail out
      return nil
    end
  end

  if old_count == 0 and new_count == 0 then
    return nil
  end

  local header = "--- a/" .. file_path .. "\n"
  .. "+++ b/" .. file_path .. "\n"
  .. "@@ -1," .. old_count .. " +1," .. new_count .. " @@\n"

  return header .. table.concat(unified_lines, "\n") .. "\n"
end

-- Reset the difftool cache (for testing).
local function reset_difftool_cache()
  _difftool_cache = nil
end

-- Cache for find_pager result across calls.
-- false means "already checked, not found"; nil means "not yet checked"
local _pager_cache: string | boolean = nil

-- Find a pager for rendering read tool output with syntax highlighting.
-- Checks AH_PAGER env var first, then autodetects bat. Returns command or nil.
local function find_pager(): string
  if _pager_cache ~= nil then
    if _pager_cache == false then
      return nil
    end
    return _pager_cache as string
  end

  local env_tool = os.getenv("AH_PAGER")
  if env_tool and env_tool ~= "" then
    _pager_cache = env_tool
    return env_tool
  end

  -- Autodetect bat at common paths
  local candidates: {string} = {
    "/usr/bin/bat",
    "/usr/local/bin/bat",
    "/opt/homebrew/bin/bat",
  }
  for _, path in ipairs(candidates) do
    local f = io.open(path, "r")
    if f then
      f:close()
      _pager_cache = path
      return path
    end
  end

  -- Try PATH via command -v
  local handle = io.popen("command -v bat 2>/dev/null")
  if handle then
    local result = handle:read("*l")
    handle:close()
    if result and result ~= "" then
      _pager_cache = result
      return result
    end
  end

  _pager_cache = false
  return nil
end

-- Run content through a pager subprocess with syntax highlighting.
-- Writes content to a temp file and pipes it to the pager with --file-name.
-- Returns rendered output string, or nil on failure.
local function run_pager(pager: string, content: string, file_name: string): string
  if not pager or content == "" then
    return nil
  end
  if not file_name or file_name == "" then
    return nil
  end
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if not f then
    return nil
  end
  f:write(content)
  f:close()
  local handle = io.popen(pager .. " --file-name=" .. file_name .. " --color=always --style=plain < " .. tmp .. " 2>/dev/null")
  if not handle then
    os.remove(tmp)
    return nil
  end
  local output = handle:read("*a")
  local ok = handle:close()
  os.remove(tmp)
  if not ok or not output or output == "" then
    return nil
  end
  return output
end

-- Reset the pager cache (for testing).
local function reset_pager_cache()
  _pager_cache = nil
end

-- Format token count as human-friendly string (e.g., 1234 -> "1.2k", 12345 -> "12.3k")
local function format_tokens(n: integer): string
  if n >= 1000000 then
    return string.format("%.1fm", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.1fk", n / 1000)
  else
    return tostring(n)
  end
end

-- Colorize a single tool output line with ANSI escape codes.
-- Uses blue+bold for success (PASS) and yellow+bold for errors (FAIL, error, exit code).
-- Uses blue/yellow instead of green/red for colorblind accessibility.
-- Returns the line (possibly colored) and a boolean indicating if color was applied.
local function colorize_tool_line(line: string): string, boolean
  if line:sub(1, 4) == "PASS" then
    return "\27[1;34m" .. line .. "\27[0m", true
  elseif line:sub(1, 4) == "FAIL" then
    return "\27[1;33m" .. line .. "\27[0m", true
  elseif line:sub(1, 6) == "error:" or line:sub(1, 6) == "Error:" then
    return "\27[1;33m" .. line .. "\27[0m", true
  elseif line:sub(1, 10) == "exit code:" then
    return "\27[1;33m" .. line .. "\27[0m", true
  end
  return line, false
end

-- CLI display handler: renders structured events to stderr/stdout for terminal use.
-- Other handlers (JSON logging, web UI, etc.) can be substituted.
local function make_cli_handler(skill_name: string, session_ulid?: string): events.EventCallback
  local is_tty = tty.isatty(2)
  local is_stdout_tty = tty.isatty(1)
  local is_ci = os.getenv("GITHUB_ACTIONS") == "true"
  local DIM = is_tty and "\27[2m" or ""
  local RESET = is_tty and "\27[0m" or ""
  local has_text = false
  local text_buffer: {string} = {}
  local captured_model: string = nil

  -- Flush buffered agent response text to stdout
  local function flush_text()
    if #text_buffer > 0 then
      local text = table.concat(text_buffer)
      if is_stdout_tty then
        text = render.render_markdown(text)
      end
      io.write(text)
      io.flush()
      text_buffer = {}
    end
  end

  return function(event: events.EventData)
    local t = event.event_type

    if t == "agent_start" then
      captured_model = event.model
      if is_ci and skill_name then
        io.stdout:write("::group::" .. skill_name .. "\n")
        io.stdout:flush()
      end
      -- In non-interactive mode, echo the prompt for clarity
      if not is_tty and event.prompt then
        io.stderr:write(">>> " .. event.prompt .. "\n")
      end

    elseif t == "text_delta" then
      -- Buffer text and print when the response is complete
      table.insert(text_buffer, event.text)
      has_text = true

    elseif t == "agent_end" then
      flush_text()
      -- Trailing newline after text output
      if has_text then
        io.write("\n")
      end
      -- Display session token totals
      local total_in = event.total_input_tokens or 0
      local total_out = event.total_output_tokens or 0
      local cache_read = event.total_cache_read_tokens or 0
      if total_in > 0 or total_out > 0 then
        io.stderr:write("\n")
        local in_str = format_tokens(total_in)
        if cache_read > 0 then
          in_str = in_str .. " (" .. format_tokens(cache_read) .. " cached)"
        end
        local total = total_in + total_out
        local budget = compact.get_context_limit(captured_model)
        local pct = math.floor(total / budget * 100)
        local sfx = session_ulid and (" [" .. session_ulid:sub(1, 8) .. "]") or ""
        io.stderr:write(string.format("%s%s in / %s out (%s/%s total, %d%%)%s%s\n", DIM, in_str, format_tokens(total_out), format_tokens(total), format_tokens(budget), pct, sfx, RESET))
      end
      if is_ci and skill_name then
        io.stdout:write("::endgroup::\n")
        io.stdout:flush()
      end

    elseif t == "budget_exceeded" then
      local total = (event.total_input_tokens or 0) + (event.total_output_tokens or 0)
      local budget = event.max_tokens or compact.get_context_limit(captured_model)
      local pct = math.floor(total / budget * 100)
      io.stderr:write(string.format("\ntoken budget exceeded (%s/%s, %d%%)\n", format_tokens(total), format_tokens(budget), pct))

    elseif t == "error" then
      local msg = event.error or "unknown"
      io.stderr:write("\nerror: " .. msg .. "\n")
      if is_ci then
        io.stdout:write("::error::" .. msg .. "\n")
        io.stdout:flush()
      end

    elseif t == "retry" then
      local attempt = event.attempt or 0
      local delay_ms = event.delay_ms or 0
      local err = event.error or "unknown error"
      local url = event.url or ""
      local elapsed_ms = event.elapsed_ms or 0
      local url_part = url ~= "" and (" [" .. url .. "]") or ""
      local elapsed_part = elapsed_ms > 0 and string.format(", %dms", elapsed_ms) or ""
      io.stderr:write(string.format("%sretrying API call%s (attempt %d, delay %dms%s): %s%s\n",
          DIM, url_part, attempt + 1, delay_ms, elapsed_part, err, RESET))

    elseif t == "api_call_end" then
      -- Flush buffered agent response text now that the response is complete
      flush_text()

    elseif t == "compaction_triggered" then
      io.stderr:write(string.format("\n%scompacting conversation (%d/%d tokens)...%s\n", DIM, event.input_tokens, event.context_limit, RESET))

    elseif t == "payload_warn" then
      local kb = math.floor((event.payload_bytes or 0) / 1024)
      local threshold_kb = math.floor((event.threshold or 0) / 1024)
      io.stderr:write(string.format("\n\27[1;33m⚠ payload size %d KB exceeds %d KB threshold — context may be too large\27[0m\n", kb, threshold_kb))

    elseif t == "compaction_complete" then
      io.stderr:write(string.format("%scompaction complete (summary: %d tokens)%s\n\n", DIM, event.output_tokens, RESET))

    elseif t == "tool_call_start" then
      -- Separator between text and first tool block
      if event.tool_index == 1 then
        if has_text then
          io.write("\n")
          has_text = false
        end
        io.stderr:write("\n")
      end

      local prefix = is_tty and "⠋ " or ""
      io.stderr:write(string.format("%s%s%s%s\n", DIM, prefix, event.tool_name, RESET))

      local key = event.tool_key or ""
      if key ~= "" then
        local indent = "  "
        local cmd_prefix = event.tool_name == "bash" and "$ " or ""
        if event.tool_name == "bash" then
          local term_width = 80
          local ws = tty.winsize(2)
          if ws then term_width = ws.cols as integer end
          local wrap_indent = indent .. "  "
          key = loop.wrap_command(key, term_width - #indent - #cmd_prefix, wrap_indent)
        end
        io.stderr:write(string.format("%s%s%s%s%s\n", DIM, indent, cmd_prefix, key, RESET))
      end

    elseif t == "tool_call_end" then
      local indent = "  "
      local elapsed = (event.duration_ms or 0) / 1000
      local key = event.tool_key or ""

      local result = event.tool_output or ""
      if result ~= "" and result ~= "(no output)" then
        -- For edit tool on a TTY, try to pipe through a difftool
        local difftool_rendered = false
        if is_tty and event.tool_name == "edit" then
          local difftool = find_difftool()
          if difftool then
            local file_path = key ~= "" and key or nil
            local unified = to_unified_diff(result, file_path)
            local rendered = run_difftool(difftool, unified or result)
            if rendered then
              io.stderr:write(rendered)
              difftool_rendered = true
            end
          end
        end

        -- For read tool on a TTY, try to pipe through a pager for syntax highlighting
        local pager_rendered = false
        if is_tty and event.tool_name == "read" and not difftool_rendered then
          local pager = find_pager()
          if pager and key ~= "" then
            local rendered = run_pager(pager, result, key)
            if rendered then
              io.stderr:write(rendered)
              pager_rendered = true
            end
          end
        end

        if not difftool_rendered and not pager_rendered then
          -- Detect diff-like commands for colorization
          local is_diff_cmd = false
          if is_tty and event.tool_name == "bash" and key ~= "" then
            is_diff_cmd = key:match("diff") ~= nil
            or key:match("show") ~= nil
            or key:match("log %-p") ~= nil
          end

          local lines: {string} = {}
          for line in result:gmatch("[^\n]+") do
            table.insert(lines, line)
          end
          local max_lines = 3
          for j = 1, math.min(max_lines, #lines) do
            local line = lines[j]
            if #line > 80 then
              line = line:sub(1, 77) .. "..."
            end
            if is_diff_cmd then
              local colored = render.colorize_diff_line(line)
              if colored ~= line then
                io.stderr:write(string.format("%s%s%s\n", indent, colored, ""))
              else
                io.stderr:write(string.format("%s%s%s%s\n", DIM, indent, line, RESET))
              end
            elseif is_tty then
              local colored, was_colored = colorize_tool_line(line)
              if was_colored then
                io.stderr:write(string.format("%s%s%s\n", indent, colored, ""))
              else
                io.stderr:write(string.format("%s%s%s%s\n", DIM, indent, line, RESET))
              end
            else
              io.stderr:write(string.format("%s%s%s%s\n", DIM, indent, line, RESET))
            end
          end
          if #lines > max_lines then
            io.stderr:write(string.format("%s%s... (%d more lines)%s\n", DIM, indent, #lines - max_lines, RESET))
          end
        end
      end

      if is_tty and event.is_error then
        io.stderr:write(string.format("%s\27[1;33m✗ %.1fs\27[0m\n", indent, elapsed))
      else
        io.stderr:write(string.format("%s%s%.1fs%s\n", indent, DIM, elapsed, RESET))
      end

      -- Blank line after tool block
      io.stderr:write("\n")
    end
  end
end

return {
  format_tokens = format_tokens,
  colorize_diff_line = render.colorize_diff_line,
  colorize_tool_line = colorize_tool_line,
  make_cli_handler = make_cli_handler,
  find_difftool = find_difftool,
  run_difftool = run_difftool,
  to_unified_diff = to_unified_diff,
  reset_difftool_cache = reset_difftool_cache,
  find_pager = find_pager,
  run_pager = run_pager,
  reset_pager_cache = reset_pager_cache,
}
