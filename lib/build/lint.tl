#!/usr/bin/env lua
-- lint: run lint rules against tracked files.
-- each file produces a pass/fail result compatible with reporter.
-- usage: lint.lua [--hierarchical-limits FILE] FILE...
--
-- with --generate-limits: read FILEs and print a limits file to stdout.
-- with --limits FILE: check FILEs against limits in FILE.

local proc = require("cosmic.proc")
local getopt = require("cosmic.getopt")

local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

-- limits ---

local record Limits
  file_lines: integer
end

local function parse_limits(path: string): {string:Limits}
  local f = io.open(path, "r")
  if not f then return {} end
  local result: {string:Limits} = {}
  for raw_line in f:lines() do
    local line = raw_line:match("^(.-)%s*#.*$") or raw_line
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
      local limit_str, name = line:match("^(%d+)%s+(.+)$")
      if limit_str and name then
        result[name] = {file_lines = tonumber(limit_str) as integer}
      end
    end
  end
  f:close()
  return result
end

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

local DEFAULT_FILE_LINES <const> = 500

local function lint_file(path: string, limits: {string:Limits}): {Diagnostic}
  local diags: {Diagnostic} = {}
  local n = count_lines(path)
  local file_limit = limits[path]
  local max = file_limit and file_limit.file_lines or DEFAULT_FILE_LINES
  for _, d in ipairs(check_file_length(path, n, max)) do
    table.insert(diags, d)
  end
  return diags
end

local function generate_limits(files: {string})
  for _, file in ipairs(files) do
    local n = count_lines(file)
    print(string.format("%d %s", n, file))
  end
end

local function main(...: string): integer, string
  local args = {...}
  local limits_path: string = nil
  local gen = false

  local longopts = {
    {name = "limits", has_arg = "required"},
    {name = "generate-limits", has_arg = "none"},
  }
  local parser = getopt.new(args, "", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "limits" then
      limits_path = optarg
    elseif opt == "generate-limits" then
      gen = true
    elseif opt == "?" then
      return 1, "usage: lint.lua [--limits FILE | --generate-limits] FILE..."
    end
  end

  local files = parser:remaining()
  if #files == 0 then
    return 1, "usage: lint.lua [--limits FILE | --generate-limits] FILE..."
  end

  if gen then
    generate_limits(files)
    return 0, nil
  end

  local limits: {string:Limits} = {}
  if limits_path then
    limits = parse_limits(limits_path)
  end

  local all_diags: {Diagnostic} = {}
  for _, file in ipairs(files) do
    for _, d in ipairs(lint_file(file, limits)) do
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
