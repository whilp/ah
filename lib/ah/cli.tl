-- ah/cli.tl: CLI display handler and output formatting
local tty = require("cosmic.tty")
local events = require("ah.events")
local loop = require("ah.loop")
local render = require("ah.render")
local compact = require("ah.compact")
local hl = require("ah.highlight")
local cenv = require("cosmic.env")

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

-- Colorize tool output lines: blue for PASS, yellow for errors.
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

-- CLI display handler: renders structured events to stderr/stdout.
local function make_cli_handler(skill_name: string, session_ulid?: string): events.EventCallback
  local is_tty = tty.isatty(2)
  local is_stdout_tty = tty.isatty(1)
  local is_ci = cenv.get("GITHUB_ACTIONS") == "true"
  local term = cenv.get("TERM") or ""
  local is_dumb = term == "dumb" or term == ""
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
        local glow = hl.find_glow()
        if glow then
          local rendered = hl.run_glow(glow, text)
          if rendered then
            text = rendered
          end
        end
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

      local key = event.tool_key or ""
      local prefix = is_dumb and "> " or "⠋ "

      if event.tool_name == "bash" then
        local term_width = 80
        local ws = tty.winsize(2)
        if ws then term_width = ws.cols as integer end
        local wrap_indent = "    "
        local available = term_width - #prefix - 2 -- 2 for "$ "
        local wrapped = loop.wrap_command(key, available, wrap_indent)
        io.stderr:write(string.format("%s%s$ %s%s\n", DIM, prefix, wrapped, RESET))
      elseif key ~= "" then
        io.stderr:write(string.format("%s%s%s %s%s\n", DIM, prefix, event.tool_name, key, RESET))
      else
        io.stderr:write(string.format("%s%s%s%s\n", DIM, prefix, event.tool_name, RESET))
      end

    elseif t == "tool_call_end" then
      local indent = "  "
      local elapsed = (event.duration_ms or 0) / 1000
      local key = event.tool_key or ""

      local result = event.tool_output or ""
      if result ~= "" and result ~= "(no output)" then
        local rendered = false

        -- TTY rendering: try specialized tools first
        if is_tty then
          local difftool = hl.find_difftool()

          -- edit tool: pipe through delta with compact headers
          if not rendered and event.tool_name == "edit" and difftool then
            local file_path = key ~= "" and key or nil
            local unified = hl.to_unified_diff(result, file_path)
            local lang = hl.infer_language(file_path)
            local out = hl.run_difftool(difftool, unified or result, {
                "--hunk-header-style=omit",
              }, lang)
            if out then
              if out:sub(-1) ~= "\n" then out = out .. "\n" end
              io.stderr:write(out); rendered = true
            end
          end

          -- read/write tool: syntax highlighting via bat, then head/tail
          if not rendered and (event.tool_name == "read" or event.tool_name == "write") then
            local pager = hl.find_pager()
            if pager and key ~= "" then
              local out = hl.run_pager(pager, result, key)
              if out then
                if out:sub(-1) ~= "\n" then out = out .. "\n" end
                -- Apply head/tail compression on highlighted output
                local hlines: {string} = {}
                for hline in out:gmatch("([^\n]*)\n") do
                  table.insert(hlines, hline)
                end
                local head_n = 5
                local tail_n = 5
                if #hlines > head_n + tail_n then
                  for j = 1, head_n do
                    io.stderr:write(indent .. hlines[j] .. "\n")
                  end
                  io.stderr:write(string.format("%s%s... (%d lines hidden) ...%s\n", DIM, indent, #hlines - head_n - tail_n, RESET))
                  for j = #hlines - tail_n + 1, #hlines do
                    io.stderr:write(indent .. hlines[j] .. "\n")
                  end
                elseif #hlines > head_n then
                  for j = 1, head_n do
                    io.stderr:write(indent .. hlines[j] .. "\n")
                  end
                  io.stderr:write(string.format("%s%s... (%d more lines)%s\n", DIM, indent, #hlines - head_n, RESET))
                else
                  for j = 1, #hlines do
                    io.stderr:write(indent .. hlines[j] .. "\n")
                  end
                end
                rendered = true
              end
            end
          end

          -- bash diff commands: pipe through delta
          if not rendered and event.tool_name == "bash" and difftool and key ~= "" then
            local is_diff_cmd = key:match("diff") ~= nil
            or key:match("show") ~= nil
            or key:match("log %-p") ~= nil
            if is_diff_cmd then
              -- Infer language from first file path in diff headers or shebang
              local first_file = result:match("%-%-%- a/([^\n]+)")
              -- Extract first content line after @@ header for shebang detection.
              -- Strip the leading diff prefix (space, +, or -) to get the raw line.
              local raw_first = result:match("@@[^\n]*\n[ +-]([^\n]*\n)")
              local lang = hl.infer_language(first_file, raw_first)
              local out = hl.run_difftool(difftool, result, nil, lang)
              if out then
                if out:sub(-1) ~= "\n" then out = out .. "\n" end
                io.stderr:write(out); rendered = true
              end
            end
          end
        end

        if not rendered then
          local lines: {string} = {}
          for line in result:gmatch("[^\n]+") do
            table.insert(lines, line)
          end
          if event.tool_name == "bash" then
            while #lines > 0 and (lines[#lines]:match("^exit code: %d+$") or lines[#lines]:match("^error: command timed out")) do
              table.remove(lines)
            end
          end

          -- Strip read/write/result tool line number prefixes (N\t) for display
          if event.tool_name == "read" or event.tool_name == "write" or event.tool_name == "result" then
            for j = 1, #lines do
              lines[j] = lines[j]:gsub("^%d+\t", "")
            end
          end

          -- Display helper: print a single line with optional colorization
          local function print_line(line: string)
            if render.display_width(line) > 80 then
              line = render.utf8_truncate(line, 77, "...")
            end
            if is_tty then
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

          local head_count = 5
          local tail_count = 5
          if #lines > head_count + tail_count then
            -- Large output: show first 5 and last 5
            for j = 1, head_count do
              print_line(lines[j])
            end
            io.stderr:write(string.format("%s%s... (%d lines hidden) ...%s\n", DIM, indent, #lines - head_count - tail_count, RESET))
            for j = #lines - tail_count + 1, #lines do
              print_line(lines[j])
            end
          elseif #lines > head_count then
            -- Medium output: show first 5 + summary
            for j = 1, head_count do
              print_line(lines[j])
            end
            io.stderr:write(string.format("%s%s... (%d more lines)%s\n", DIM, indent, #lines - head_count, RESET))
          else
            -- Small output: show all
            for j = 1, #lines do
              print_line(lines[j])
            end
          end
        end
      end

      -- Summary line with braille bracket: duration, line count, error status
      local line_count = 0
      if result ~= "" and result ~= "(no output)" then
        for _ in result:gmatch("\n") do line_count = line_count + 1 end
        if result:sub(-1) ~= "\n" then line_count = line_count + 1 end
      end
      local suffix = is_dumb and "< " or "⠜ "
      local parts: {string} = {}
      table.insert(parts, string.format("%.1fs", elapsed))
      if line_count > 0 then
        table.insert(parts, string.format("%d line%s", line_count, line_count == 1 and "" or "s"))
      end
      if event.is_error then
        if event.tool_name == "bash" then
          local code = result:match("exit code: (%d+)")
          if code then table.insert(parts, "exit " .. code)
          else table.insert(parts, "error") end
        else
          table.insert(parts, "error")
        end
      end
      local summary = table.concat(parts, ", ")
      io.stderr:write(string.format("%s%s%s%s\n", DIM, suffix, summary, RESET))

      -- Blank line after tool block
      io.stderr:write("\n")
    end
  end
end

return {
  format_tokens = format_tokens,
  colorize_tool_line = colorize_tool_line,
  make_cli_handler = make_cli_handler,
}
