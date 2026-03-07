-- ah/cli.tl: CLI display handler and output formatting
local tty = require("cosmic.tty")
local child = require("cosmic.child")
local unix = require("cosmo.unix")
local events = require("ah.events")
local loop = require("ah.loop")
local render = require("ah.render")
local compact = require("ah.compact")

-- ToolFinder holds a find function and a reset function for a cached tool lookup.
local record ToolFinder
  find: function(): string
  reset: function()
end

-- make_tool_finder returns a ToolFinder that checks env_var first, then walks
-- candidates via io.open, then falls back to unix.commandv for PATH lookup.
-- tool_names is a list of command names to try via commandv, in priority order.
-- Each finder maintains its own independent cache.
local function make_tool_finder(env_var: string, candidates: {string}, tool_names: {string}): ToolFinder
  local cache: string | boolean = nil

  local function find(): string
    if cache ~= nil then
      if cache == false then
        return nil
      end
      return cache as string
    end

    local env_tool = os.getenv(env_var)
    if env_tool and env_tool ~= "" then
      cache = env_tool
      return env_tool
    end

    for _, path in ipairs(candidates) do
      local f = io.open(path, "r")
      if f then
        f:close()
        cache = path
        return path
      end
    end

    for _, name in ipairs(tool_names) do
      local result = unix.commandv(name)
      if result then
        cache = result
        return result
      end
    end

    cache = false
    return nil
  end

  local function reset()
    cache = nil
  end

  return {find = find, reset = reset}
end

-- run_piped passes content via stdin to tool with extra_args.
-- Returns rendered output string, or nil on failure.
local function run_piped(tool: string, content: string, extra_args: {string}): string
  if not tool or content == "" then
    return nil
  end

  -- Build argv: tool is always a bare path, append extra_args elements
  local argv: {string} = {tool}
  if extra_args then
    for _, arg in ipairs(extra_args) do
      table.insert(argv, arg)
    end
  end

  local h, _ = child.spawn(argv, {stdin = content})
  if not h then
    return nil
  end
  -- Ignore ok and exit code: tools like delta exit 1 when showing diffs,
  -- but their stdout is still valid output. Empty stdout means no output.
  local _, stdout, _ = h:read()
  local output = (stdout as string) or ""
  if output == "" then
    return nil
  end
  return output
end

-- difftool_finder: find/reset for delta
local _difftool_finder = make_tool_finder("AH_DIFFTOOL",
  {"/usr/bin/delta", "/usr/local/bin/delta", "/opt/homebrew/bin/delta"},
  {"delta"})

-- Find a difftool. Checks AH_DIFFTOOL env var first, then autodetects delta.
local function find_difftool(): string
  return _difftool_finder.find()
end

-- Run diff text through a difftool subprocess with optional extra_args.
-- Returns rendered output string, or nil on failure.
local function run_difftool(difftool: string, diff_text: string, extra_args?: {string}): string
  return run_piped(difftool, diff_text, extra_args or {})
end

-- Convert the edit tool's pseudo-diff ("- "/"+ " prefixed lines) to unified diff format
-- so tools like delta can parse and syntax-highlight the output.
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
  _difftool_finder.reset()
end

-- pager_finder: find/reset for dat or bat
local _pager_finder = make_tool_finder("AH_PAGER",
  {"/usr/bin/dat", "/usr/local/bin/dat", "/opt/homebrew/bin/dat",
    "/usr/bin/bat", "/usr/local/bin/bat", "/opt/homebrew/bin/bat"},
  {"dat", "bat"})

-- Find a pager. Checks AH_PAGER env var first, then autodetects dat or bat.
local function find_pager(): string
  return _pager_finder.find()
end

-- Run content through a pager subprocess with syntax highlighting.
-- Strips N\t line number prefixes before piping (for better highlighting),
-- then re-adds them to the highlighted output.
-- Returns rendered output string, or nil on failure.
local function run_pager(pager: string, content: string, file_name: string): string
  if not file_name or file_name == "" then
    return nil
  end

  -- Strip line number prefixes (N\t) and collect them for re-insertion
  local prefixes: {string} = {}
  local stripped = content:gsub("([^\n]*)", function(line: string): string
      local num, rest = line:match("^(%d+)\t(.*)$")
      if num then
        table.insert(prefixes, num .. "\t")
        return rest
      end
      table.insert(prefixes, "")
      return line
    end)

  local highlighted = run_piped(pager, stripped, {"--file-name=" .. file_name, "--color=always", "--style=plain"})
  if not highlighted then
    return nil
  end

  -- Re-add line number prefixes to highlighted output lines
  local i = 0
  local result = highlighted:gsub("([^\n]*)", function(line: string): string
      i = i + 1
      local pfx = i <= #prefixes and prefixes[i] or ""
      return pfx .. line
    end)
  return result
end

-- Reset the pager cache (for testing).
local function reset_pager_cache()
  _pager_finder.reset()
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
  local term = os.getenv("TERM") or ""
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
        -- For edit tool on a TTY, try to pipe through a difftool
        local difftool_rendered = false
        if is_tty and event.tool_name == "edit" then
          local difftool = find_difftool()
          if difftool then
            local file_path = key ~= "" and key or nil
            local unified = to_unified_diff(result, file_path)
            local rendered = run_difftool(difftool, unified or result, {
                "--file-style=omit",
                "--hunk-header-style=omit",
                "--paging=never",
              })
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
          -- For bash, strip trailing "exit code: N" / timeout lines (shown in ⠜ summary)
          if event.tool_name == "bash" then
            while #lines > 0 and (lines[#lines]:match("^exit code: %d+$") or lines[#lines]:match("^error: command timed out")) do
              table.remove(lines)
            end
          end
          local max_lines = 3
          for j = 1, math.min(max_lines, #lines) do
            local line = lines[j]
            if render.display_width(line) > 80 then
              line = render.utf8_truncate(line, 77, "...")
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
  find_difftool = find_difftool,
  run_difftool = run_difftool,
  to_unified_diff = to_unified_diff,
  reset_difftool_cache = reset_difftool_cache,
  find_pager = find_pager,
  run_pager = run_pager,
  reset_pager_cache = reset_pager_cache,
}
