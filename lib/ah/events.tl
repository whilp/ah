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
end

local type EventCallback = function(event: EventData)

  -- Construct an event with common fields populated
  local function make_event(event_type: string): EventData
    return {
      event_type = event_type,
      timestamp = os.time() as number,
    }
  end

  -- Convenience constructors for each event type

  local function agent_start(model: string, prompt: string, parent_id: string): EventData
    local e = make_event("agent_start")
    e.model = model
    e.prompt = prompt
    e.parent_id = parent_id
    return e
  end

  local function agent_end(stop_reason: string, total_input_tokens: integer, total_output_tokens: integer, error_message: string, total_cache_read_tokens: integer): EventData
    local e = make_event("agent_end")
    e.stop_reason = stop_reason
    e.total_input_tokens = total_input_tokens
    e.total_output_tokens = total_output_tokens
    if total_cache_read_tokens and total_cache_read_tokens > 0 then
      e.total_cache_read_tokens = total_cache_read_tokens
    end
    if error_message then
      e.error = error_message
    end
    return e
  end

  local function api_call_start(): EventData
    return make_event("api_call_start")
  end

  local function api_call_end(message_id: string, input_tokens: integer, output_tokens: integer, api_latency_ms: integer, model: string, cache_creation_input_tokens: integer, cache_read_input_tokens: integer): EventData
    local e = make_event("api_call_end")
    e.message_id = message_id
    e.input_tokens = input_tokens
    e.output_tokens = output_tokens
    e.cache_creation_input_tokens = cache_creation_input_tokens
    e.cache_read_input_tokens = cache_read_input_tokens
    e.api_latency_ms = api_latency_ms
    e.model = model
    return e
  end

  local function tool_call_start(tool_name: string, tool_input: string, tool_key: string, index: integer, count: integer): EventData
    local e = make_event("tool_call_start")
    e.tool_name = tool_name
    e.tool_input = tool_input
    e.tool_key = tool_key
    e.tool_index = index
    e.tool_count = count
    return e
  end

  local function tool_call_end(tool_name: string, tool_output: string, is_error: boolean, duration_ms: integer, tool_key: string, index: integer, count: integer): EventData
    local e = make_event("tool_call_end")
    e.tool_name = tool_name
    e.tool_output = tool_output
    e.is_error = is_error
    e.duration_ms = duration_ms
    e.tool_key = tool_key
    e.tool_index = index
    e.tool_count = count
    return e
  end

  local function text_delta(text: string): EventData
    local e = make_event("text_delta")
    e.text = text
    return e
  end

  local function error_event(err: string): EventData
    local e = make_event("error")
    e.error = err
    return e
  end

  local function retry_event(attempt: integer, delay_ms: integer, status: integer, err: string): EventData
    local e = make_event("retry")
    e.attempt = attempt
    e.delay_ms = delay_ms
    e.status = status
    e.error = err
    return e
  end

  local function state_change(from_state: string, to_state: string): EventData
    local e = make_event("state_change")
    e.from_state = from_state
    e.to_state = to_state
    return e
  end

  local function steering_received(content: string, message_count: integer): EventData
    local e = make_event("steering_received")
    e.content = content
    e.message_count = message_count
    return e
  end

  local function followup_received(content: string, message_count: integer): EventData
    local e = make_event("followup_received")
    e.content = content
    e.message_count = message_count
    return e
  end

  local function loop_detected(consecutive_count: integer, signature: string, action: string): EventData
    local e = make_event("loop_detected")
    e.consecutive_count = consecutive_count
    e.turn_signature = signature
    e.action = action
    return e
  end

  local function compaction_triggered(input_tokens: integer, context_limit: integer): EventData
    local e = make_event("compaction_triggered")
    e.input_tokens = input_tokens
    e.context_limit = context_limit
    return e
  end

  local function compaction_complete(input_tokens: integer, output_tokens: integer): EventData
    local e = make_event("compaction_complete")
    e.input_tokens = input_tokens
    e.output_tokens = output_tokens
    return e
  end

  local function budget_exceeded(total_input_tokens: integer, total_output_tokens: integer, max_tokens: integer): EventData
    local e = make_event("budget_exceeded")
    e.total_input_tokens = total_input_tokens
    e.total_output_tokens = total_output_tokens
    e.max_tokens = max_tokens
    return e
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

    -- Serialization
    to_json = to_json,
  }
