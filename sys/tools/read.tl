-- sys/tools/read.tl: read file tool
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local codec = require("cosmic.codec")
local json = require("cosmic.json")

local IMAGE_TYPES: {string: string} = {
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  png = "image/png",
  gif = "image/gif",
  webp = "image/webp",
}

local function is_binary(content: string): boolean
  local sample_size = math.min(#content, 8192)
  local sample = content:sub(1, sample_size)

  if sample:find("\0") then
    return true
  end

  local non_printable = 0
  for i = 1, #sample do
    local b = sample:byte(i)
    if not ((b >= 32 and b <= 126) or b == 9 or b == 10 or b == 13) then
      if b < 128 then
        non_printable = non_printable + 1
      end
    end
  end

  return non_printable > sample_size * 0.1
end

return {
  name = "read",
  description = "Read contents of a file (supports text and images: jpg, png, gif, webp)",
  system_prompt = "Use read to examine files before editing. Do not use cat to read files.",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to read"},
      offset = {type = "integer", description = "Line number to start reading from (1-indexed, text only)"},
      limit = {type = "integer", description = "Maximum number of lines to read (text only)"},
    },
    required = {"path"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local file_path = input.path as string
    if not file_path then
      return "error: path is required", true
    end

    local ext = file_path:match("%.([^%.]+)$")
    if ext then
      ext = ext:lower()
    end
    local media_type = ext and IMAGE_TYPES[ext]

    if media_type then
      local content = cio.slurp(file_path)
      if not content then
        return "error: failed to read file: " .. file_path, true
      end

      local base64_data = codec.encode_base64(content)
      local image_block = {
        __image__ = true,
        content = {{
            type = "image",
            source = {
              type = "base64",
              media_type = media_type,
              data = base64_data,
            },
          }},
      }
      return json.encode(image_block), false, {path = file_path, bytes = #content, media_type = media_type}
    end

    local content = cio.slurp(file_path)
    if not content then
      return "error: failed to read file: " .. file_path, true
    end

    if is_binary(content) then
      return string.format("error: %s appears to be a binary file (%d bytes)", file_path, #content), true
    end

    local offset = (input.offset as integer) or 1
    local limit = (input.limit as integer) or 0

    local total_lines = 0
    for _ in content:gmatch("[^\n]*") do
      total_lines = total_lines + 1
    end

    if offset > 1 or limit > 0 then
      local lines: {string} = {}
      local line_num = 0
      for line in content:gmatch("[^\n]*") do
        line_num = line_num + 1
        if line_num >= offset then
          if limit > 0 and line_num >= offset + limit then
            break
          end
          table.insert(lines, string.format("%d\t%s", line_num, line))
        end
      end
      return table.concat(lines, "\n"), false, {path = file_path, line_count = total_lines}
    end

    local lines: {string} = {}
    local line_num = 0
    for line in content:gmatch("[^\n]*") do
      line_num = line_num + 1
      table.insert(lines, string.format("%d\t%s", line_num, line))
    end
    return table.concat(lines, "\n"), false, {path = file_path, line_count = total_lines}
  end,
}
