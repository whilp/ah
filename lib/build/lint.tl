#!/usr/bin/env lua
-- lint: run lint rules against tracked files.
-- each file produces a pass/fail result compatible with reporter.
-- usage: lint.lua FILE...

local proc = require("cosmic.proc")

local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

-- limits ---

local DEFAULT_FILE_LINES <const> = 500

local FILE_LINES: {string:integer} = {
  ["lib/ah/db.tl"] = 549,
  ["lib/ah/init.tl"] = 1359,
  ["lib/ah/loop.tl"] = 952,
  ["lib/ah/test_db.tl"] = 506,
  ["lib/ah/test_init.tl"] = 688,
  ["lib/ah/test_tools.tl"] = 1563,
  ["lib/ah/tools.tl"] = 734,
}

-- rules ---

local function count_lines(path: string): integer
  local f = io.open(path, "r")
  if not f then return 0 end
  local n = 0
  for _ in f:lines() do
    n = n + 1
  end
  f:close()
  return n
end

local function check_file_length(
  file: string, n: integer, limit: integer
): {Diagnostic}
  if n <= limit then return {} end
  return {{
    file = file,
    line = n,
    col = 0,
    rule = "file-length",
    message = string.format(
      "%d lines (limit: %d)", n, limit
    ),
  }}
end

-- runner ---

local function lint_file(path: string): {Diagnostic}
  local diags: {Diagnostic} = {}
  local n = count_lines(path)
  local max = FILE_LINES[path] or DEFAULT_FILE_LINES
  for _, d in ipairs(check_file_length(path, n, max)) do
    table.insert(diags, d)
  end
  return diags
end

local function main(...: string): integer, string
  local args = {...}
  if #args == 0 then
    return 1, "usage: lint.lua FILE..."
  end

  local all_diags: {Diagnostic} = {}
  for _, file in ipairs(args) do
    for _, d in ipairs(lint_file(file)) do
      table.insert(all_diags, d)
    end
  end

  if #all_diags == 0 then
    print("pass:")
  else
    print(string.format("fail: %d issues", #all_diags))
    print("")
    for _, d in ipairs(all_diags) do
      print(string.format(
        "%s:%d:%d: %s: %s", d.file, d.line, d.col, d.rule, d.message
      ))
    end
  end

  return #all_diags == 0 and 0 or 1, nil
end

if proc.is_main() then
  local code, err = main(...)
  if err then
    io.stderr:write(err .. "\n")
  end
  os.exit(code)
end
