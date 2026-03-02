-- ah/events.tl: structured event system for agent lifecycle
local json = require("cosmic.json")

-- Event types covering the full agent lifecycle:
--   agent_start, agent_end
--   api_call_start, api_call_end
--   tool_call_start, tool_call_end
--   text_delta (streaming text output)
--   error, retry
--   state_change (session state transitions: idle/processing/closed)
--   steering_received, followup_received (queue messages)

local record EventData
  -- Common fields
  event_type: string
  timestamp: number

  -- agent_start / agent_end
  model: string
  prompt: string
  parent_id: string
  stop_reason: string

  -- api_call_start / api_call_end
  input_tokens: integer
  output_tokens: integer
  cache_creation_input_tokens: integer
  cache_read_input_tokens: integer
  api_latency_ms: integer
  message_id: string

  -- tool_call_start / tool_call_end
  tool_name: string
  tool_input: string
  tool_key: string
  tool_output: string
  is_error: boolean
  duration_ms: integer
  tool_index: integer
  tool_count: integer

  -- text_delta
  text: string

  -- error
  error: string

  -- retry
  attempt: integer
  delay_ms: integer
  status: integer
  url: string
  elapsed_ms: integer

  -- state_change
  from_state: string
  to_state: string

  -- steering/followup
  content: string
  message_count: integer

  -- loop_detected
  consecutive_count: integer
  turn_signature: string
  action: string -- "warn" or "break"

  -- compaction
  context_limit: integer

  -- token budget
  total_input_tokens: integer
  total_output_tokens: integer
  total_cache_read_tokens: integer
  max_tokens: integer

  -- payload size tracking
  payload_bytes: integer
  threshold: integer
end

local type EventCallback = function(event: EventData)

  -- Construct an event with common fields populated.
  -- If fields is provided, it is used as the base table (mutated in place).
  local function make_event(event_type: string, fields?: EventData): EventData
    local e = fields or {} as EventData
    e.event_type = event_type
    e.timestamp = os.time() as number
    return e
  end

  -- Convenience constructors for each event type

  local function agent_start(model: string, prompt: string, parent_id: string): EventData
    return make_event("agent_start", {model = model, prompt = prompt, parent_id = parent_id} as EventData)
  end

  local function agent_end(stop_reason: string, total_input_tokens: integer, total_output_tokens: integer, error_message: string, total_cache_read_tokens: integer): EventData
    local fields = {stop_reason = stop_reason, total_input_tokens = total_input_tokens, total_output_tokens = total_output_tokens} as EventData
    if total_cache_read_tokens and total_cache_read_tokens > 0 then
      fields.total_cache_read_tokens = total_cache_read_tokens
    end
    if error_message then
      fields.error = error_message
    end
    return make_event("agent_end", fields)
  end

  local function api_call_start(payload_bytes: integer): EventData
    return make_event("api_call_start", {payload_bytes = payload_bytes} as EventData)
  end

  local function payload_warn(payload_bytes: integer, threshold: integer): EventData
    return make_event("payload_warn", {payload_bytes = payload_bytes, threshold = threshold} as EventData)
  end

  local function api_call_end(message_id: string, input_tokens: integer, output_tokens: integer, api_latency_ms: integer, model: string, cache_creation_input_tokens: integer, cache_read_input_tokens: integer): EventData
    return make_event("api_call_end", {message_id = message_id, input_tokens = input_tokens, output_tokens = output_tokens, cache_creation_input_tokens = cache_creation_input_tokens, cache_read_input_tokens = cache_read_input_tokens, api_latency_ms = api_latency_ms, model = model} as EventData)
  end

  local function tool_call_start(tool_name: string, tool_input: string, tool_key: string, index: integer, count: integer): EventData
    return make_event("tool_call_start", {tool_name = tool_name, tool_input = tool_input, tool_key = tool_key, tool_index = index, tool_count = count} as EventData)
  end

  local function tool_call_end(tool_name: string, tool_output: string, is_error: boolean, duration_ms: integer, tool_key: string, index: integer, count: integer): EventData
    return make_event("tool_call_end", {tool_name = tool_name, tool_output = tool_output, is_error = is_error, duration_ms = duration_ms, tool_key = tool_key, tool_index = index, tool_count = count} as EventData)
  end

  local function text_delta(text: string): EventData
    return make_event("text_delta", {text = text} as EventData)
  end

  local function error_event(err: string): EventData
    return make_event("error", {error = err} as EventData)
  end

  local function retry_event(attempt: integer, delay_ms: integer, status: integer, err: string, url: string, elapsed_ms: integer): EventData
    local fields = {attempt = attempt, delay_ms = delay_ms, status = status, error = err} as EventData
    if url and url ~= "" then
      fields.url = url
    end
    if elapsed_ms and elapsed_ms > 0 then
      fields.elapsed_ms = elapsed_ms
    end
    return make_event("retry", fields)
  end

  local function state_change(from_state: string, to_state: string): EventData
    return make_event("state_change", {from_state = from_state, to_state = to_state} as EventData)
  end

  local function steering_received(content: string, message_count: integer): EventData
    return make_event("steering_received", {content = content, message_count = message_count} as EventData)
  end

  local function followup_received(content: string, message_count: integer): EventData
    return make_event("followup_received", {content = content, message_count = message_count} as EventData)
  end

  local function loop_detected(consecutive_count: integer, signature: string, action: string): EventData
    return make_event("loop_detected", {consecutive_count = consecutive_count, turn_signature = signature, action = action} as EventData)
  end

  local function compaction_triggered(input_tokens: integer, context_limit: integer): EventData
    return make_event("compaction_triggered", {input_tokens = input_tokens, context_limit = context_limit} as EventData)
  end

  local function compaction_complete(input_tokens: integer, output_tokens: integer): EventData
    return make_event("compaction_complete", {input_tokens = input_tokens, output_tokens = output_tokens} as EventData)
  end

  local function budget_exceeded(total_input_tokens: integer, total_output_tokens: integer, max_tokens: integer): EventData
    return make_event("budget_exceeded", {total_input_tokens = total_input_tokens, total_output_tokens = total_output_tokens, max_tokens = max_tokens} as EventData)
  end

  -- Serialize an event to JSON (for persistence or JSON logging)
  local function to_json(event: EventData): string
    local t: {string: any} = {}
    for k, v in pairs(event as {string: any}) do
      if v ~= nil then
        t[k] = v
      end
    end
    local result = json.encode(t)
    return result
  end

  return {
    -- Types
    EventData = EventData,
    EventCallback = EventCallback,

    -- Constructors
    make_event = make_event,
    agent_start = agent_start,
    agent_end = agent_end,
    api_call_start = api_call_start,
    api_call_end = api_call_end,
    tool_call_start = tool_call_start,
    tool_call_end = tool_call_end,
    text_delta = text_delta,
    error_event = error_event,
    retry_event = retry_event,
    state_change = state_change,
    steering_received = steering_received,
    followup_received = followup_received,
    loop_detected = loop_detected,
    compaction_triggered = compaction_triggered,
    compaction_complete = compaction_complete,
    budget_exceeded = budget_exceeded,
    payload_warn = payload_warn,

    -- Serialization
    to_json = to_json,
  }
