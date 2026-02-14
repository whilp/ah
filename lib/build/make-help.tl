#!/usr/bin/env cosmic
local cio = require("cosmic.io")
local proc = require("cosmic.proc")

local record Item
  type: string
  name: string
  description: string
end

local function parse_makefile(content: string): {Item}
  local items: {Item} = {}
  local pending_comment: string = nil

  for line in content:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")

    local comment = trimmed:match("^##%s*(.*)$")
    if comment then
      if pending_comment then
        pending_comment = pending_comment .. " " .. comment
      else
        pending_comment = comment
      end
      goto continue
    end

    local target_match = trimmed:match("^([a-zA-Z_][a-zA-Z0-9_-]*):%s*(.*)$")
    if target_match then
      if pending_comment then
        table.insert(items, {
          type = "target",
          name = target_match,
          description = pending_comment,
        })
      end
      pending_comment = nil
      goto continue
    end

    local var_match = trimmed:match("^([a-zA-Z_][a-zA-Z0-9_-]*)%s*[?:]?=%s*")
    if var_match then
      if pending_comment then
        table.insert(items, {
          type = "option",
          name = var_match,
          description = pending_comment,
        })
      end
      pending_comment = nil
      goto continue
    end

    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%.") then
      pending_comment = nil
    end

    ::continue::
  end

  return items
end

local function format_help(items: {Item}): string
  local width = 20
  local output: {string} = {}
  local targets: {Item} = {}
  local vars: {Item} = {}

  for _, item in ipairs(items) do
    if item.type == "target" then
      table.insert(targets, item)
    elseif item.type == "option" then
      table.insert(vars, item)
    end
  end

  table.insert(output, "Usage: make [target] [options]")
  table.insert(output, "")
  table.insert(output, "Targets:")

  for _, item in ipairs(targets) do
    local padding = string.rep(" ", math.max(0, width - #item.name))
    table.insert(output, "  " .. item.name .. padding .. item.description)
  end

  if #vars > 0 then
    table.insert(output, "")
    table.insert(output, "Options:")
    for _, item in ipairs(vars) do
      local padding = string.rep(" ", math.max(0, width - #item.name))
      table.insert(output, "  " .. item.name .. padding .. item.description)
    end
  end

  return table.concat(output, "\n")
end

local function main(args: {string}): number, string
  local makefile = args[1] or "Makefile"

  local content, err = cio.slurp(makefile)
  if not content then
    return 1, err or ("Failed to read " .. makefile)
  end

  local targets = parse_makefile(content)
  print(format_help(targets))
  return 0
end

if proc.is_main() then
  local exit_code, err = main(arg)
  if err then
    io.stderr:write(err .. "\n")
  end
  os.exit(exit_code)
end
