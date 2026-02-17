-- ah/api.lua: Claude Messages API with streaming
local json = require("cosmic.json")
local fetch = require("cosmic.fetch")
local time = require("cosmic.time")
local auth = require("ah.auth")

-- Detect proxy from environment (set by work.tl for sandboxed processes).
-- Resolved lazily so envd.load() has time to set vars before first use.
local function get_proxy_url(): string
  local http_proxy = os.getenv("https_proxy") or os.getenv("HTTPS_PROXY")
                  or os.getenv("http_proxy") or os.getenv("HTTP_PROXY")
  if http_proxy and http_proxy:sub(1, 7) == "unix://" then
    local path = http_proxy:sub(8)
    local url, err = fetch.unix_proxy(path)
    if url then
      return url
    else
      io.stderr:write("[api] warning: invalid proxy url: " .. (err or "unknown") .. "\n")
    end
  end
  return nil
end

-- Tool name mapping for Claude Code compatibility (OAuth mode)
local CLAUDE_CODE_TOOLS: {string:string} = {
  read = "Read",
  write = "Write",
  edit = "Edit",
  bash = "Bash",
}

-- Reverse mapping for inbound tool calls
local CLAUDE_CODE_TOOLS_REVERSE: {string:string} = {
  Read = "read",
  Write = "write",
  Edit = "edit",
  Bash = "bash",
}

local function to_claude_code_name(name: string): string
  return CLAUDE_CODE_TOOLS[name] or name
end

local function from_claude_code_name(name: string): string
  return CLAUDE_CODE_TOOLS_REVERSE[name] or name
end

-- Get monotonic time in milliseconds
local function now_ms(): integer
  local s, ns = time.monotonic()
  return math.floor(s * 1000 + ns / 1e6) as integer
end

-- Resolve API URL lazily so envd.load() has time to set ANTHROPIC_BASE_URL.
local function get_api_url(): string
  local base = os.getenv("ANTHROPIC_BASE_URL")
  if base then
    -- Strip trailing slash before appending path
    return base:gsub("/$", "") .. "/v1/messages"
  else
    return "https://api.anthropic.com/v1/messages"
  end
end
local DEFAULT_MODEL = "claude-opus-4-6"
local DEFAULT_MAX_TOKENS = 16384

local MODELS: {string} = {
  "claude-sonnet-4-5-20250929",
  "claude-opus-4-5-20251101",
  "claude-opus-4-6",
  "claude-opus-4-6-1m",
  "claude-haiku-4-5-20251001",
}

local MODEL_ALIASES: {string:string} = {
  ["sonnet"] = "claude-sonnet-4-5-20250929",
  ["opus"] = "claude-opus-4-6",
  ["opus-1m"] = "claude-opus-4-6-1m",
  ["haiku"] = "claude-haiku-4-5-20251001",
}

-- Resolve model name, expanding aliases
local function resolve_model(name: string): string
  if not name then return nil end
  return MODEL_ALIASES[name] or name
end
local CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."

local MAX_RETRIES = 3
local BASE_DELAY_MS = 1000
local MAX_RETRY_DELAY_MS = 60000

-- Check if an error is retryable (rate limits, server errors)
local function is_retryable_error(status: integer, error_text: string): boolean
  -- Retryable status codes
  if status == 429 or status == 500 or status == 502 or status == 503 or status == 504 then
    return true
  end
  -- Check error text for rate limit patterns
  local text = (error_text or ""):lower()
  if text:match("rate[%s_-]*limit") or text:match("overloaded") then
    return true
  end
  return false
end

-- Extract retry delay from headers or error message
-- Returns delay in milliseconds, or nil if not found
local function extract_retry_delay(error_text: string, headers: {string:string}): integer
  headers = headers or {}

  -- Check Retry-After header (seconds)
  local retry_after = headers["retry-after"] or headers["Retry-After"]
  if retry_after then
    local seconds = tonumber(retry_after)
    if seconds and seconds > 0 then
      return math.floor(seconds * 1000) as integer
    end
  end

  -- Check x-ratelimit-reset-after header (seconds)
  local reset_after = headers["x-ratelimit-reset-after"]
  if reset_after then
    local seconds = tonumber(reset_after)
    if seconds and seconds > 0 then
      return math.floor(seconds * 1000) as integer
    end
  end

  -- Parse error text patterns
  local text = error_text or ""

  -- "retry in Xs" or "retry in Xms"
  local retry_seconds = text:match("retry in (%d+)s")
  if retry_seconds then
    return math.floor(tonumber(retry_seconds) * 1000) as integer
  end
  local retry_ms = text:match("retry in (%d+)ms")
  if retry_ms then
    return math.floor(tonumber(retry_ms)) as integer
  end

  -- "reset after Xs" or "reset after XhYmZs"
  local reset_seconds = text:match("reset after (%d+)s")
  if reset_seconds then
    return math.floor(tonumber(reset_seconds) * 1000) as integer
  end

  return nil
end

-- Sleep for given milliseconds using nanosleep (no fork overhead)
local function sleep_ms(ms: integer)
  local seconds = math.floor(ms / 1000)
  local nanos = (ms % 1000) * 1000000
  time.sleep(seconds, nanos)
end

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

  -- Format system prompt with cache_control on the last block
  -- Anthropic caches up to the marked breakpoint, reducing input token costs
  if is_oauth then
    -- OAuth: Claude Code identity MUST be in first system block, user prompt in second
    local system_blocks: {{string:any}} = {{type = "text", text = CLAUDE_CODE_IDENTITY}}
    if opts.system then
      table.insert(system_blocks, {type = "text", text = opts.system as string, cache_control = {type = "ephemeral"}})
    else
      system_blocks[1].cache_control = {type = "ephemeral"}
    end
    req.system = system_blocks
  elseif opts.system then
    -- Non-OAuth: system prompt as array with cache_control on the block
    req.system = {{type = "text", text = opts.system as string, cache_control = {type = "ephemeral"}}}
  end

  -- Only include tools if provided (allows testing without tools)
  if opts.tools and #(opts.tools as {any}) > 0 then
    if is_oauth then
      -- Remap tool names to Claude Code format for OAuth
      local remapped: {{string:any}} = {}
      for _, tool in ipairs(opts.tools as {{string:any}}) do
        table.insert(remapped, {
          name = to_claude_code_name(tool.name as string),
          description = tool.description,
          input_schema = tool.input_schema,
        })
      end
      req.tools = remapped
    else
      req.tools = opts.tools
    end
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
-- is_interrupted: optional callback that returns true when the caller wants to abort mid-stream
local function stream(messages: {any}, opts: {string:any}, callback: function({string:any}), is_interrupted: function(): boolean): {string:any}, string
  local creds, err = auth.load_credentials()
  if not creds then
    return nil, err
  end

  opts = opts or {}
  opts.stream = true

  local model = (opts.model or DEFAULT_MODEL) as string
  local req = build_request(messages, opts, creds.is_oauth or false)
  local auth_headers = auth.get_auth_headers(creds)
  local body = json.encode(req)

  -- Track timing and retries
  local start_ms = now_ms()
  local retries: {{string:any}} = {}

  -- Retry loop for transient errors
  local reader: fetch.Reader = nil
  local last_error: string = nil

  for attempt = 0, MAX_RETRIES do
    local stream_result = fetch.stream(get_api_url(), {
      method = "POST",
      headers = auth_headers,
      body = body,
      proxy = get_proxy_url(),
    } as fetch.Opts)

    if not stream_result.ok then
      last_error = "fetch failed: " .. (stream_result.error or "unknown error")
      -- Network errors are retryable
      if attempt < MAX_RETRIES then
        -- Exponential backoff with jitter: base * 2^attempt * (0.5 + rand(0.5))
        local base_delay = BASE_DELAY_MS * (2 ^ attempt)
        local jitter = 0.5 + math.random() * 0.5
        local delay_ms = math.floor(base_delay * jitter) as integer
        table.insert(retries, {attempt = attempt, error = last_error, delay_ms = delay_ms})
        sleep_ms(delay_ms)
      end
    elseif stream_result.status == 200 then
      reader = stream_result.reader
      break
    else
      local status = stream_result.status as integer
      -- Read error body for non-200 responses
      local error_chunks: {string} = {}
      if stream_result.reader then
        for chunk in stream_result.reader.read, stream_result.reader do
          table.insert(error_chunks, chunk)
        end
        stream_result.reader:close()
      end
      local error_body = table.concat(error_chunks)
      last_error = parse_api_error(status, error_body)

      if attempt < MAX_RETRIES and is_retryable_error(status, error_body) then
        -- Try to get delay from headers or error message
        local delay_ms: integer = extract_retry_delay(error_body, stream_result.headers as {string:string})
        if not delay_ms then
          -- Exponential backoff with jitter
          local base_delay = BASE_DELAY_MS * (2 ^ attempt)
          local jitter = 0.5 + math.random() * 0.5
          delay_ms = math.floor(base_delay * jitter) as integer
        end
        -- Fail fast if server requests excessive delay
        if delay_ms > MAX_RETRY_DELAY_MS then
          local delay_secs = math.ceil(delay_ms / 1000)
          local max_secs = math.ceil(MAX_RETRY_DELAY_MS / 1000)
          return nil, string.format("server requested %ds retry delay (max: %ds). %s", delay_secs, max_secs, last_error)
        end
        table.insert(retries, {attempt = attempt, status = status, error = last_error, delay_ms = delay_ms})
        sleep_ms(delay_ms)
      else
        return nil, last_error
      end
    end
  end

  if not reader then
    return nil, last_error or "fetch failed"
  end

  -- Parse SSE response with true streaming
  local response: {string:any} = nil
  local current_block: {string:any} = nil
  local block_index: integer = nil
  local content_blocks: {integer:{string:any}} = {}
  local was_interrupted = false

  for line in reader:lines() do
    -- Check for interruption between SSE events
    if is_interrupted and is_interrupted() then
      was_interrupted = true
      break
    end

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

  reader:close()

  -- On interruption, finalize partial response with accumulated content
  if was_interrupted and response then
    -- Finalize any in-progress block
    if current_block and block_index ~= nil then
      if current_block.partial_json then
        -- Try to parse partial tool input; drop it if invalid
        local parsed_input = json.decode(current_block.partial_json as string)
        if parsed_input then
          current_block.input = parsed_input
        end
        current_block.partial_json = nil
      end
      content_blocks[block_index + 1] = current_block
    end
    response.content = content_blocks
    response.stop_reason = "interrupted"
  end

  -- For OAuth, convert tool names back from Claude Code format
  if creds.is_oauth and response and response.content then
    for _, block in ipairs(response.content as {any}) do
      local b = block as {string:any}
      if b.type == "tool_use" and b.name then
        b.name = from_claude_code_name(b.name as string)
      end
    end
  end

  -- Add timing and metadata
  if response then
    response.api_latency_ms = now_ms() - start_ms
    response.model = model
    if #retries > 0 then
      response.retries = retries
    end
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
  is_retryable_error = is_retryable_error,
  extract_retry_delay = extract_retry_delay,
  resolve_model = resolve_model,
  to_claude_code_name = to_claude_code_name,
  from_claude_code_name = from_claude_code_name,
  get_api_url = get_api_url,
  get_proxy_url = get_proxy_url,
  DEFAULT_MODEL = DEFAULT_MODEL,
  MODEL_ALIASES = MODEL_ALIASES,
  MAX_RETRIES = MAX_RETRIES,
  BASE_DELAY_MS = BASE_DELAY_MS,
  MAX_RETRY_DELAY_MS = MAX_RETRY_DELAY_MS,
}
