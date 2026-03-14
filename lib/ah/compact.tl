-- ah/compact.tl: context compaction for long conversations
--
-- When a conversation approaches the model's context window limit, compaction
-- summarizes the history so the agent can continue. This is a view-layer
-- operation: compaction only affects what is sent to the API. The full
-- conversation is always preserved in the database.

local json = require("cosmic.json")
local api = require("ah.api")

-- Model context window limits (tokens) — sourced from api.MODEL_CONTEXT_LIMITS
local MODEL_CONTEXT_LIMITS = api.MODEL_CONTEXT_LIMITS

local DEFAULT_CONTEXT_LIMIT = 1000000

-- Compaction triggers when input_tokens / context_limit exceeds this ratio
local DEFAULT_THRESHOLD = 0.8

local COMPACTION_SYSTEM_PROMPT = [[Summarize this conversation for continuation in a new context window. Preserve:
- What was accomplished so far
- Current work in progress
- Files read, written, or edited (include full paths)
- Pending next steps
- Key constraints or decisions made
- Any errors encountered and how they were resolved

Be thorough but concise. This summary will replace the full conversation history.]]

local record CompactResult
  summary: string
  input_tokens: integer
  output_tokens: integer
end

-- Get context window limit for a model (tokens)
local function get_context_limit(model: string): integer
  if model then
    return MODEL_CONTEXT_LIMITS[model] or DEFAULT_CONTEXT_LIMIT
  end
  return DEFAULT_CONTEXT_LIMIT
end

-- Check if compaction is needed based on token usage from the last API response
local function needs_compaction(input_tokens: integer, model: string, threshold?: number): boolean
  if not input_tokens or input_tokens == 0 then
    return false
  end
  threshold = threshold or DEFAULT_THRESHOLD
  local limit = get_context_limit(model)
  return (input_tokens / limit) > threshold
end

-- Sanitize api_messages for compaction: convert tool_use and tool_result blocks
-- to text blocks so the API doesn't reject them (no tools declared in the request).
-- After conversion, merge consecutive same-role messages and remove empty ones.
local function sanitize_for_compaction(api_messages: {any}): {any}
  -- First pass: convert tool_use / tool_result blocks to text blocks
  local converted: {any} = {}
  for _, msg in ipairs(api_messages) do
    local m = msg as {string: any}
    local role = m.role as string
    local orig_content = m.content as {any}
    if not orig_content then
      goto next_msg
    end

    local new_content: {any} = {}
    for _, block in ipairs(orig_content) do
      local b = block as {string: any}
      local btype = b.type as string
      if btype == "tool_use" then
        local name = (b.name or "") as string
        local input_str = json.encode(b.input or {})
        local text = "[Tool: " .. name .. "]\n" .. input_str
        table.insert(new_content, {type = "text", text = text})
      elseif btype == "tool_result" then
        local tid = (b.tool_use_id or "") as string
        local raw = b.content
        local content_str: string
        if type(raw) == "string" then
          content_str = raw as string
        elseif type(raw) == "table" then
          local parts: {string} = {}
          local raw_arr = raw as {any}
          for _, item in ipairs(raw_arr) do
            local it = item as {string: any}
            if it.type == "text" and it.text then
              table.insert(parts, it.text as string)
            end
          end
          content_str = table.concat(parts, "\n")
        else
          content_str = ""
        end
        local text = "[Tool result: " .. tid .. "]\n" .. content_str
        table.insert(new_content, {type = "text", text = text})
      else
        table.insert(new_content, block)
      end
    end

    if #new_content > 0 then
      table.insert(converted, {role = role, content = new_content})
    end
    ::next_msg::
  end

  -- Second pass: merge consecutive same-role messages
  local merged: {any} = {}
  for _, msg in ipairs(converted) do
    local m = msg as {string: any}
    local role = m.role as string
    local content = m.content as {any}
    if #merged > 0 then
      local prev = merged[#merged] as {string: any}
      if prev.role == role then
        local prev_content = prev.content as {any}
        for _, block in ipairs(content) do
          table.insert(prev_content, block)
        end
        goto next_merged
      end
    end
    table.insert(merged, {role = role, content = content})
    ::next_merged::
  end

  return merged
end

-- Perform compaction: send current conversation to the API with a summarization
-- prompt (no tools). Returns a CompactResult with the summary text, or nil and
-- an error string.
local function compact(api_messages: {any}, model: string, is_interrupted: function(): boolean): CompactResult, string
  -- Sanitize messages before calling API (removes tool_use/tool_result blocks)
  local sanitized = sanitize_for_compaction(api_messages)

  -- Call API with sanitized messages and compaction system prompt (no tools)
  local response, err = api.stream(sanitized, {
      system = COMPACTION_SYSTEM_PROMPT,
      model = model,
    } as {string: any}, nil, is_interrupted)

  if err then
    return nil, "compaction failed: " .. err
  end

  if not response then
    return nil, "compaction failed: no response"
  end

  local resp = response as {string: any}

  -- If interrupted mid-compaction, bail out
  if resp.stop_reason == "interrupted" then
    return nil, "compaction interrupted"
  end

  -- Extract text from response content blocks
  local summary_parts: {string} = {}
  local resp_content = resp.content as {any}
  if resp_content then
    for _, block in ipairs(resp_content) do
      local b = block as {string: any}
      if b.type == "text" and b.text then
        table.insert(summary_parts, b.text as string)
      end
    end
  end

  local summary = table.concat(summary_parts)
  if summary == "" then
    return nil, "compaction failed: empty summary"
  end

  local usage = (resp.usage or {}) as {string: any}

  return {
    summary = summary,
    input_tokens = (usage.input_tokens or 0) as integer,
    output_tokens = (usage.output_tokens or 0) as integer,
  }, nil
end

return {
  needs_compaction = needs_compaction,
  compact = compact,
  sanitize_for_compaction = sanitize_for_compaction,
  get_context_limit = get_context_limit,
  CompactResult = CompactResult,
  MODEL_CONTEXT_LIMITS = MODEL_CONTEXT_LIMITS,
  DEFAULT_CONTEXT_LIMIT = DEFAULT_CONTEXT_LIMIT,
  DEFAULT_THRESHOLD = DEFAULT_THRESHOLD,
  COMPACTION_SYSTEM_PROMPT = COMPACTION_SYSTEM_PROMPT,
}
