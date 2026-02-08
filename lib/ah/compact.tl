-- ah/compact.tl: context compaction for long conversations
--
-- When a conversation approaches the model's context window limit, compaction
-- summarizes the history so the agent can continue. This is a view-layer
-- operation: compaction only affects what is sent to the API. The full
-- conversation is always preserved in the database.

local api = require("ah.api")

-- Model context window limits (tokens)
local MODEL_CONTEXT_LIMITS: {string:integer} = {
  ["claude-sonnet-4-20250514"] = 200000,
  ["claude-opus-4-20250514"] = 200000,
  ["claude-haiku-3-20250314"] = 200000,
}

local DEFAULT_CONTEXT_LIMIT = 200000

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

-- Perform compaction: send current conversation to the API with a summarization
-- prompt (no tools). Returns a CompactResult with the summary text, or nil and
-- an error string.
local function compact(api_messages: {any}, model: string, is_interrupted: function(): boolean): CompactResult, string
  -- Call API with existing messages and compaction system prompt (no tools)
  local response, err = api.stream(api_messages, {
    system = COMPACTION_SYSTEM_PROMPT,
    model = model,
  } as {string:any}, nil, is_interrupted)

  if err then
    return nil, "compaction failed: " .. err
  end

  if not response then
    return nil, "compaction failed: no response"
  end

  local resp = response as {string:any}

  -- If interrupted mid-compaction, bail out
  if resp.stop_reason == "interrupted" then
    return nil, "compaction interrupted"
  end

  -- Extract text from response content blocks
  local summary_parts: {string} = {}
  local resp_content = resp.content as {any}
  if resp_content then
    for _, block in ipairs(resp_content) do
      local b = block as {string:any}
      if b.type == "text" and b.text then
        table.insert(summary_parts, b.text as string)
      end
    end
  end

  local summary = table.concat(summary_parts)
  if summary == "" then
    return nil, "compaction failed: empty summary"
  end

  local usage = (resp.usage or {}) as {string:any}

  return {
    summary = summary,
    input_tokens = (usage.input_tokens or 0) as integer,
    output_tokens = (usage.output_tokens or 0) as integer,
  }, nil
end

return {
  needs_compaction = needs_compaction,
  compact = compact,
  get_context_limit = get_context_limit,
  CompactResult = CompactResult,
  MODEL_CONTEXT_LIMITS = MODEL_CONTEXT_LIMITS,
  DEFAULT_CONTEXT_LIMIT = DEFAULT_CONTEXT_LIMIT,
  DEFAULT_THRESHOLD = DEFAULT_THRESHOLD,
  COMPACTION_SYSTEM_PROMPT = COMPACTION_SYSTEM_PROMPT,
}
