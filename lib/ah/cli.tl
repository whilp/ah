-- ah/cli.tl: CLI display handler and output formatting
local tty = require("cosmic.tty")
local events = require("ah.events")
local loop = require("ah.loop")
local render = require("ah.render")
local compact = require("ah.compact")

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

-- Colorize a single diff line with ANSI escape codes.
-- Uses blue/yellow instead of green/red for colorblind accessibility.
-- Returns the line with color prefix/suffix applied, or unchanged if not a diff line.
local function colorize_diff_line(line: string): string
  if line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" then
    return "\27[1m" .. line .. "\27[0m"
  elseif line:sub(1, 2) == "@@" then
    return "\27[36m" .. line .. "\27[0m"
  elseif line:sub(1, 1) == "+" then
    return "\27[34m" .. line .. "\27[0m"
  elseif line:sub(1, 1) == "-" then
    return "\27[33m" .. line .. "\27[0m"
  end
  return line
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
-- This is the application-layer implementation of the event callback.
-- Other handlers (JSON logging, web UI, etc.) can be substituted.
local function make_cli_handler(skill_name: string): events.EventCallback
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
        io.stderr:write(string.format("%s%s in / %s out (%s/%s total, %d%%)%s\n", DIM, in_str, format_tokens(total_out), format_tokens(total), format_tokens(budget), pct, RESET))
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

    elseif t == "api_call_end" then
      -- Flush buffered agent response text now that the response is complete
      flush_text()

    elseif t == "compaction_triggered" then
      io.stderr:write(string.format("\n%scompacting conversation (%d/%d tokens)...%s\n", DIM, event.input_tokens, event.context_limit, RESET))

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

    elseif t == "tool_call_end" then
      local indent = "  "
      local elapsed = (event.duration_ms or 0) / 1000

      -- Line 1: tool name and timing
      -- Use yellow+bold with ✗ prefix for errors, dim with ⠋ for success
      if is_tty and event.is_error then
        io.stderr:write(string.format("\27[1;33m✗ %s (%.1fs)\27[0m\n", event.tool_name, elapsed))
      else
        local prefix = is_tty and "⠋ " or ""
        io.stderr:write(string.format("%s%s%s (%.1fs)%s\n", DIM, prefix, event.tool_name, elapsed, RESET))
      end

      -- Line 2: command (for bash) or key param
      local key = event.tool_key or ""
      if key ~= "" then
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

      -- Show truncated output (first 3 lines, then count)
      local result = event.tool_output or ""
      if result ~= "" and result ~= "(no output)" then
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
            local colored = colorize_diff_line(line)
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

      -- Blank line after tool block
      io.stderr:write("\n")
    end
  end
end

return {
  format_tokens = format_tokens,
  colorize_diff_line = colorize_diff_line,
  colorize_tool_line = colorize_tool_line,
  make_cli_handler = make_cli_handler,
}
