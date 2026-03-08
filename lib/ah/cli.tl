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

-- make_tool_finder returns a ToolFinder that checks env_var, then candidates, then PATH.
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
-- Optional env_overrides: {"KEY=VALUE", ...} merged into the current environment.
local function run_piped(tool: string, content: string, extra_args: {string}, env_overrides?: {string}): string
  if not tool or content == "" then
    return nil
  end

  -- Build argv
  local argv: {string} = {tool}
  if extra_args then
    for _, arg in ipairs(extra_args) do
      table.insert(argv, arg)
    end
  end

  -- Build environment if overrides specified
  local env: {string} = nil
  if env_overrides then
    env = unix.environ() as {string}
    for _, override in ipairs(env_overrides) do
      local key = (override as string):match("^([^=]+)=")
      if key then
        local prefix = key .. "="
        local found = false
        for i, entry in ipairs(env) do
          if (entry as string):sub(1, #prefix) == prefix then
            env[i] = override
            found = true
            break
          end
        end
        if not found then
          table.insert(env, override)
        end
      end
    end
  end

  local h, _ = child.spawn(argv, {stdin = content, env = env})
  if not h then
    return nil
  end
  -- Ignore exit code: tools like delta exit 1 on diffs but stdout is valid.
  local _, stdout, _ = h:read()
  local output = (stdout as string) or ""
  if output == "" then
    return nil
  end
  return output
end

-- difftool: delta
local _difftool = make_tool_finder("AH_DIFFTOOL",
  {"/usr/bin/delta", "/usr/local/bin/delta", "/opt/homebrew/bin/delta"}, {"delta"})

local function find_difftool(): string return _difftool.find() end
local function reset_difftool_cache() _difftool.reset() end

-- Base delta args: no external config, diff-so-fancy style.
-- Syntax-highlighted with muted background colors:
--   removed lines: dark red background (#3f1515), emphasis (#6b2020)
--   added lines: dark blue background (#0d2744), emphasis (#133d6b)
local DELTA_BASE_ARGS: {string} = {
  "--no-gitconfig",
  "--diff-so-fancy",
  "--paging=never",
  "--syntax-theme=base16",
  '--minus-style=syntax "#3f1515"',
  '--minus-emph-style=syntax "#6b2020"',
  '--plus-style=syntax "#0d2744"',
  '--plus-emph-style=syntax "#133d6b"',
  "--file-style=omit",
  "--hunk-header-decoration-style=blue",
}

-- Map file extensions to delta --default-language values.
-- Only needed for extensions delta/syntect don't recognize natively.
local EXT_LANG_MAP: {string: string} = {
  tl = "Lua",
}

-- Map shebang interpreters to delta --default-language values.
local SHEBANG_LANG_MAP: {string: string} = {
  cosmic = "Lua",
}

-- Infer language from a file path's extension via EXT_LANG_MAP,
-- falling back to shebang detection in content.
local function infer_language(path: string, content?: string): string
  if path then
    local ext = path:match("%.([^%.]+)$")
    if ext and EXT_LANG_MAP[ext] then return EXT_LANG_MAP[ext] end
  end
  if content then
    local interp = content:match("^#!.-/([%w_%-]+)%s*\n")
      or content:match("^#!.-/env%s+([%w_%-]+)")
    if interp and SHEBANG_LANG_MAP[interp] then
      return SHEBANG_LANG_MAP[interp]
    end
  end
  return nil
end

local function run_difftool(difftool: string, diff_text: string, extra_args?: {string}, language?: string): string
  local args: {string} = {}
  for _, a in ipairs(DELTA_BASE_ARGS) do table.insert(args, a) end
  if language then
    table.insert(args, "--default-language=" .. language)
  end
  if extra_args then
    for _, a in ipairs(extra_args) do table.insert(args, a) end
  end
  return run_piped(difftool, diff_text, args)
end

-- Convert edit tool pseudo-diff to unified diff for delta.
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

  local header = "diff --git a/" .. file_path .. " b/" .. file_path .. "\n"
  .. "--- a/" .. file_path .. "\n"
  .. "+++ b/" .. file_path .. "\n"
  .. "@@ -1," .. old_count .. " +1," .. new_count .. " @@\n"

  return header .. table.concat(unified_lines, "\n") .. "\n"
end

-- glow: markdown renderer
local _glow = make_tool_finder("AH_GLOW",
  {"/usr/bin/glow", "/usr/local/bin/glow", "/opt/homebrew/bin/glow"}, {"glow"})

local function find_glow(): string return _glow.find() end
local function reset_glow_cache() _glow.reset() end

-- Resolve the glow style: use embedded JSON style if available, fall back to "dark".
local _glow_style: string = nil
local function glow_style(): string
  if _glow_style then return _glow_style end
  local embedded = "/zip/embed/sys/glow.json"
  local f = io.open(embedded, "r")
  if f then
    f:close()
    _glow_style = embedded
  else
    _glow_style = "dark"
  end
  return _glow_style
end

local function run_glow(glow: string, text: string): string
  local width = "0"
  local ws = tty.winsize(1)  -- stdout
  if ws then
    width = tostring(ws.cols as integer)
  end
  -- CLICOLOR_FORCE=1 ensures glow emits ANSI colors even when piped.
  return run_piped(glow, text, {"-s", glow_style(), "-w", width, "-"}, {"CLICOLOR_FORCE=1"})
end

-- pager: bat
local _pager = make_tool_finder("AH_PAGER",
  {"/usr/bin/bat", "/usr/local/bin/bat", "/opt/homebrew/bin/bat"}, {"bat"})

local function find_pager(): string return _pager.find() end
local function reset_pager_cache() _pager.reset() end

-- Run content through bat with syntax highlighting.
-- Strips line number prefixes (N\t) before highlighting; does not re-add them.
local function run_pager(pager: string, content: string, file_name: string): string
  if not file_name or file_name == "" then
    return nil
  end

  -- Strip line number prefixes (N\t) from tool output
  local stripped = content:gsub("([^\n]*)", function(line: string): string
      local _, rest = line:match("^(%d+)\t(.*)$")
      if rest then
        return rest
      end
      return line
    end)

  local highlighted = run_piped(pager, stripped, {"--file-name=" .. file_name, "--color=always", "--style=plain", "--map-syntax=*.tl:Lua"})
  return highlighted
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
        local glow = find_glow()
        if glow then
          local rendered = run_glow(glow, text)
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
          local difftool = find_difftool()

          -- edit tool: pipe through delta with compact headers
          if not rendered and event.tool_name == "edit" and difftool then
            local file_path = key ~= "" and key or nil
            local unified = to_unified_diff(result, file_path)
            local lang = infer_language(file_path)
            local out = run_difftool(difftool, unified or result, {
                "--hunk-header-style=omit",
              }, lang)
            if out then
              if out:sub(-1) ~= "\n" then out = out .. "\n" end
              io.stderr:write(out); rendered = true
            end
          end

          -- read/write tool: syntax highlighting via bat, then head/tail
          if not rendered and (event.tool_name == "read" or event.tool_name == "write") then
            local pager = find_pager()
            if pager and key ~= "" then
              local out = run_pager(pager, result, key)
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
              local lang = infer_language(first_file, raw_first)
              local out = run_difftool(difftool, result, nil, lang)
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

          -- Strip read/write tool line number prefixes (N\t) for display
          if event.tool_name == "read" or event.tool_name == "write" then
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
  find_difftool = find_difftool,
  run_difftool = run_difftool,
  to_unified_diff = to_unified_diff,
  reset_difftool_cache = reset_difftool_cache,
  DELTA_BASE_ARGS = DELTA_BASE_ARGS,
  infer_language = infer_language,
  find_glow = find_glow,
  run_glow = run_glow,
  glow_style = glow_style,
  reset_glow_cache = reset_glow_cache,
  find_pager = find_pager,
  run_pager = run_pager,
  reset_pager_cache = reset_pager_cache,
}
