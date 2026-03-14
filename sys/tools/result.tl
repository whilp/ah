-- sys/tools/result.tl: read full output of a previous tool call from the session DB
local db = require("ah.db")

return {
  name = "result",
  description = "Read full output of a previous tool call by tool_use_id (use when output was truncated)",
  system_prompt = "When tool output is truncated, use the result tool with the tool_use_id from the truncation notice to read the full output. Use offset and limit to page through large results.",
  input_schema = {
    type = "object",
    properties = {
      tool_use_id = {type = "string", description = "The tool_use_id from the truncated result"},
      offset = {type = "integer", description = "Line number to start reading from (1-indexed, default: 1)"},
      limit = {type = "integer", description = "Maximum number of lines to return (default: all)"},
    },
    required = {"tool_use_id"},
  },
  execute = function(input: {string: any}, context: any): string, boolean, any
    local d = context and (context as {string: any}).db as db.DB
    if not d then
      return "error: no active session", true
    end

    local tool_use_id = input.tool_use_id as string
    if not tool_use_id or tool_use_id == "" then
      return "error: tool_use_id is required", true
    end

    -- Query content_blocks for the matching tool_result
    local output: string = nil
    for row in d._db:query(
      "select tool_output from content_blocks where block_type = 'tool_result' and tool_id = ?",
      tool_use_id
    ) do
      output = row.tool_output as string
    end

    if not output then
      return "error: no tool result found for tool_use_id: " .. tool_use_id, true
    end

    local offset = (input.offset as integer) or 1
    local limit_val = (input.limit as integer) or 0

    if offset <= 1 and limit_val == 0 then
      return output, false
    end

    -- Split into lines and apply offset/limit
    local all_lines: {string} = {}
    for line in output:gmatch("[^\n]*") do
      table.insert(all_lines, line)
    end
    if #all_lines > 0 and all_lines[#all_lines] == "" and output:sub(-1) == "\n" then
      table.remove(all_lines)
    end
    local total_lines = #all_lines

    local lines: {string} = {}
    for i = offset, total_lines do
      if limit_val > 0 and i >= offset + limit_val then
        break
      end
      table.insert(lines, string.format("%d\t%s", i, all_lines[i]))
    end

    local end_line = offset + (limit_val > 0 and limit_val - 1 or total_lines) as integer
    if end_line > total_lines then end_line = total_lines end
    local header = string.format("[lines %d-%d of %d]\n", offset, end_line, total_lines)
    return header .. table.concat(lines, "\n"), false
  end,
}
