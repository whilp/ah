#!/usr/bin/env lua
local cosmo = require("cosmo")
local getopt = require("cosmo.getopt")

local record CheckResult
  status: string
  message: string
  name: string
  file: string
  checker: string
  output: string
end

local record CategorizedResults
  pass: {CheckResult}
  fail: {CheckResult}
  skip: {CheckResult}
  ignore: {CheckResult}
end

local function parse_result(content: string): CheckResult
  local result: CheckResult = {}
  local first_line, rest = content:match("^([^\n]*)\n?(.*)")
  if not first_line then
    return nil
  end
  local status, message = first_line:match("^(%w+):?%s*(.*)")
  result.status = status or first_line
  result.message = message ~= "" and message or nil
  result.output = rest or ""
  return result
end

local function strip_prefix(filepath: string, dir: string): string
  if filepath:sub(1, #dir) == dir and filepath:sub(#dir + 1, #dir + 1) == "/" then
    return filepath:sub(#dir + 2)
  end
  return filepath
end

local function extract_checker(filename: string): string
  return filename:match("%.([^%.]+)%.ok$")
end

local function truncate_lines(text: string, max_lines: integer): string
  if not text or text == "" then return text end
  local lines: {string} = {}
  local count = 0
  for line in text:gmatch("[^\n]*") do
    count = count + 1
    if count <= max_lines then
      table.insert(lines, line)
    end
  end
  if count > max_lines then
    table.insert(lines, string.format("... (%d more lines)", count - max_lines))
  end
  return table.concat(lines, "\n")
end

local function main(...: string): integer, string
  local args = {...}
  local dir: string = nil

  local longopts = {{"dir", "required"}}
  local parser = getopt.new(args, "", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "dir" then
      dir = optarg
    elseif opt == "?" then
      return 1, "usage: reporter.lua --dir DIR FILES..."
    end
  end

  local files = parser:remaining()
  if not files or #files == 0 then
    return 1, "usage: reporter.lua --dir DIR FILES..."
  end
  if not dir then
    return 1, "error: --dir is required"
  end

  local icons = {pass = "✓", fail = "✗", skip = "→", ignore = "○"}
  local results: CategorizedResults = {pass = {}, fail = {}, skip = {}, ignore = {}}
  local all_results: {CheckResult} = {}

  table.sort(files)

  for _, file in ipairs(files) do
    local content = cosmo.Slurp(file)
    if content then
      local parsed = parse_result(content)
      if parsed then
        local checker = extract_checker(file)
        local strip_suffix = "%." .. (checker or "test"):gsub("%-", "%%-") .. "%.ok$"
        local result: CheckResult = {
          status = parsed.status,
          message = parsed.message,
          output = parsed.output,
          name = strip_prefix(file, dir):gsub(strip_suffix, ""),
          file = file,
          checker = checker,
        }
        local status_list = (results as {string:{CheckResult}})[result.status]
        if status_list then
          table.insert(status_list, result)
        end
        table.insert(all_results, result)
      end
    end
  end

  local lines: {string} = {}
  for _, result in ipairs(all_results) do
    local status = string.upper(result.status)
    local icon = (icons as {string:string})[result.status] or " "
    local checker = result.checker or ""
    local line = string.format("%s %-6s %-8s %s", icon, status, checker, result.name)
    if result.status ~= "pass" and result.message then
      line = line .. " (" .. result.message .. ")"
    end
    table.insert(lines, line)
  end

  local total = #results.pass + #results.fail + #results.skip + #results.ignore
  table.insert(lines, "")
  table.insert(lines, string.format(
    "test: %d checks: %d passed, %d failed, %d skipped, %d ignored",
    total, #results.pass, #results.fail, #results.skip, #results.ignore
  ))

  if #results.fail > 0 then
    table.insert(lines, "")
    table.insert(lines, "FAILURES:")
    for _, result in ipairs(results.fail) do
      table.insert(lines, "")
      table.insert(lines, string.format("--- %s ---", result.name))
      if result.message then
        table.insert(lines, result.message)
      end
      if result.output and result.output ~= "" then
        table.insert(lines, truncate_lines(result.output, 10))
      end
    end
  end

  print(table.concat(lines, "\n"))
  return #results.fail == 0 and 0 or 1, nil
end

if cosmo.is_main() then
  local code, err = main(...)
  if err then
    io.stderr:write(err .. "\n")
  end
  os.exit(code)
end
