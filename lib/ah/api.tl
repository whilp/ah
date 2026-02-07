-- ah/api.lua: Claude Messages API with streaming
local json = require("cosmic.json")
local fetch = require("cosmic.fetch")
local unix = require("cosmo.unix")
local auth = require("ah.auth")
local tools_mod = require("ah.tools")
local spinner = require("ah.spinner")

-- ANSI styling (only when stderr is a tty)
local is_tty = unix.isatty(2)
local DIM = is_tty and "\27[2m" or ""
local RESET = is_tty and "\27[0m" or ""

-- Get monotonic time in seconds
local function now(): number
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return s + ns / 1e9
end

local API_URL = "https://api.anthropic.com/v1/messages"

-- Fix empty Lua tables that should be JSON arrays
-- Lua can't distinguish {} (object) from [] (array), so empty tables encode as {}
-- The API expects content fields to be arrays, so we fix them via string replacement
local function fix_empty_arrays(json_str: string): string
  -- Fix "content":{} -> "content":[]
  -- This handles both message content and tool_result content
  return (json_str:gsub('"content":%{%}', '"content":[]'))
end
local DEFAULT_MODEL = "claude-sonnet-4-20250514"
local DEFAULT_MAX_TOKENS = 8192
local CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."

-- Parse API error response to extract clean message
local function parse_api_error(status: integer, body: string): string
  local err_body = body or ""
  if err_body ~= "" then
    local parsed = json.decode(err_body) as {string:any}
    if parsed and parsed.error then
      local e = parsed.error as {string:any}
      if e.message then
        return string.format("API error %d: %s", status, e.message as string)
      end
    end
  end
  return string.format("API error %d: %s", status, err_body)
end

local function build_request(messages: {any}, opts: {string:any}, is_oauth: boolean): {string:any}
  opts = opts or {}
  local req: {string:any} = {
    model = opts.model or DEFAULT_MODEL,
    max_tokens = opts.max_tokens or DEFAULT_MAX_TOKENS,
    messages = messages,
    stream = opts.stream ~= false,
  }

  -- Format system prompt
  if is_oauth then
    -- OAuth: Claude Code identity MUST be in first system block, user prompt in second
    local system_blocks: {{string:any}} = {{type = "text", text = CLAUDE_CODE_IDENTITY}}
    if opts.system then
      table.insert(system_blocks, {type = "text", text = opts.system as string})
    end
    req.system = system_blocks
  elseif opts.system then
    req.system = opts.system
  end

  -- Only include tools if provided (allows testing without tools)
  if opts.tools and #(opts.tools as {any}) > 0 then
    req.tools = opts.tools
  end
  return req
end

-- Parse SSE stream line by line
local function parse_sse_line(line: string): string, string
  if line:match("^data: ") then
    return "data", line:sub(7)
  elseif line:match("^event: ") then
    return "event", line:sub(8)
  end
  return nil, nil
end

-- Stream API call with callback for each event
local function stream(messages: {any}, opts: {string:any}, callback: function({string:any})): {string:any}, string
  local creds, err = auth.load_credentials()
  if not creds then
    return nil, err
  end

  opts = opts or {}
  opts.stream = true

  local req = build_request(messages, opts, creds.is_oauth or false)
  local headers = auth.get_auth_headers(creds)
  local encoded = json.encode(req)
  local body = fix_empty_arrays(encoded)

  -- Start spinner while waiting for API
  local spin = spinner.start()
  local start = now()

  local result = fetch.Fetch(API_URL, {
    method = "POST",
    headers = headers,
    body = body,
    maxresponse = 10 * 1024 * 1024,
  } as fetch.Opts)

  local elapsed = now() - start
  spinner.stop(spin)

  if not result.ok then
    return nil, "fetch failed: " .. (result.error or "unknown error")
  end

  if result.status ~= 200 then
    return nil, parse_api_error(result.status as integer, result.body)
  end

  -- Parse SSE response
  local response: {string:any} = nil
  local current_block: {string:any} = nil
  local block_index: integer = nil
  local content_blocks: {integer:{string:any}} = {}

  for line in result.body:gmatch("[^\r\n]+") do
    local kind, data = parse_sse_line(line)
    if kind == "data" and data ~= "[DONE]" then
      local event = json.decode(data) as {string:any}
      if event then
        if callback then
          callback(event)
        end

        if event.type == "message_start" and event.message then
          response = event.message as {string:any}
          response.content = {}
        elseif event.type == "content_block_start" then
          current_block = event.content_block as {string:any}
          block_index = event.index as integer
          if current_block then
            content_blocks[block_index + 1] = current_block
          end
        elseif event.type == "content_block_delta" and event.delta then
          local delta = event.delta as {string:any}
          if current_block and delta.type == "text_delta" then
            current_block.text = ((current_block.text or "") as string) .. ((delta.text or "") as string)
          elseif current_block and delta.type == "input_json_delta" then
            -- Accumulate tool input JSON
            current_block.partial_json = ((current_block.partial_json or "") as string) .. ((delta.partial_json or "") as string)
          end
        elseif event.type == "content_block_stop" then
          if current_block and block_index ~= nil then
            -- Parse accumulated tool input JSON
            if current_block.partial_json then
              current_block.input = json.decode(current_block.partial_json as string)
              current_block.partial_json = nil
            end
            content_blocks[block_index + 1] = current_block
          end
          current_block = nil
          block_index = nil
        elseif event.type == "message_delta" then
          local delta = event.delta as {string:any}
          if response and delta then
            response.stop_reason = delta.stop_reason
          end
          if event.usage then
            response.usage = event.usage
          end
        elseif event.type == "message_stop" then
          if response then
            response.content = content_blocks
          end
        end
      end
    end
  end

  -- For OAuth, convert tool names back from Claude Code format
  if creds.is_oauth and response and response.content then
    for _, block in ipairs(response.content as {any}) do
      local b = block as {string:any}
      if b.type == "tool_use" and b.name then
        b.name = tools_mod.from_claude_code_name(b.name as string)
      end
    end
  end

  -- Attach think time to response
  if response then
    response.think_time = elapsed
  end

  return response
end

-- Extract tool calls from response
local function extract_tool_calls(response: {string:any}): {{string:any}}
  local tool_calls: {{string:any}} = {}
  if response and response.content then
    for _, block in ipairs(response.content as {any}) do
      local b = block as {string:any}
      if b.type == "tool_use" then
        table.insert(tool_calls, b)
      end
    end
  end
  return tool_calls
end

return {
  stream = stream,
  extract_tool_calls = extract_tool_calls,
  build_request = build_request,
  parse_api_error = parse_api_error,
  fix_empty_arrays = fix_empty_arrays,
  DEFAULT_MODEL = DEFAULT_MODEL,
}
