#!/usr/bin/env cosmic
-- test_events.tl: tests for the structured event system
local events = require("ah.events")
local json = require("cosmic.json")

-- Test make_event creates event with type and timestamp
local function test_make_event()
  local e = events.make_event("test_type")
  assert(e.event_type == "test_type", "event_type mismatch")
  assert(e.timestamp, "should have timestamp")
  assert(e.timestamp > 0, "timestamp should be positive")
end
test_make_event()

-- Test agent_start constructor
local function test_agent_start()
  local e = events.agent_start("claude-sonnet", "hello world", "parent123")
  assert(e.event_type == "agent_start", "event_type should be agent_start")
  assert(e.model == "claude-sonnet", "model mismatch")
  assert(e.prompt == "hello world", "prompt mismatch")
  assert(e.parent_id == "parent123", "parent_id mismatch")
end
test_agent_start()

-- Test agent_end constructor
local function test_agent_end()
  local e = events.agent_end("end_turn")
  assert(e.event_type == "agent_end", "event_type should be agent_end")
  assert(e.stop_reason == "end_turn", "stop_reason mismatch")
end
test_agent_end()

-- Test api_call_start constructor
local function test_api_call_start()
  local e = events.api_call_start()
  assert(e.event_type == "api_call_start", "event_type should be api_call_start")
  assert(e.timestamp, "should have timestamp")
end
test_api_call_start()

-- Test api_call_end constructor
local function test_api_call_end()
  local e = events.api_call_end("msg123", 100, 50, 1500, "claude-sonnet")
  assert(e.event_type == "api_call_end", "event_type should be api_call_end")
  assert(e.message_id == "msg123", "message_id mismatch")
  assert(e.input_tokens == 100, "input_tokens mismatch")
  assert(e.output_tokens == 50, "output_tokens mismatch")
  assert(e.api_latency_ms == 1500, "api_latency_ms mismatch")
  assert(e.model == "claude-sonnet", "model mismatch")
end
test_api_call_end()

-- Test tool_call_start constructor
local function test_tool_call_start()
  local e = events.tool_call_start("bash", '{"command":"ls"}', "ls", 1, 3)
  assert(e.event_type == "tool_call_start", "event_type should be tool_call_start")
  assert(e.tool_name == "bash", "tool_name mismatch")
  assert(e.tool_input == '{"command":"ls"}', "tool_input mismatch")
  assert(e.tool_key == "ls", "tool_key mismatch")
  assert(e.tool_index == 1, "tool_index mismatch")
  assert(e.tool_count == 3, "tool_count mismatch")
end
test_tool_call_start()

-- Test tool_call_end constructor
local function test_tool_call_end()
  local e = events.tool_call_end("bash", "output here", false, 250, "ls", 1, 3)
  assert(e.event_type == "tool_call_end", "event_type should be tool_call_end")
  assert(e.tool_name == "bash", "tool_name mismatch")
  assert(e.tool_output == "output here", "tool_output mismatch")
  assert(e.is_error == false, "is_error should be false")
  assert(e.duration_ms == 250, "duration_ms mismatch")
  assert(e.tool_key == "ls", "tool_key mismatch")
  assert(e.tool_index == 1, "tool_index mismatch")
  assert(e.tool_count == 3, "tool_count mismatch")
end
test_tool_call_end()

-- Test tool_call_end with error
local function test_tool_call_end_error()
  local e = events.tool_call_end("read", "error: file not found", true, 5, "/tmp/foo", 2, 2)
  assert(e.is_error == true, "is_error should be true")
  assert(e.tool_output == "error: file not found", "tool_output mismatch")
end
test_tool_call_end_error()

-- Test text_delta constructor
local function test_text_delta()
  local e = events.text_delta("Hello ")
  assert(e.event_type == "text_delta", "event_type should be text_delta")
  assert(e.text == "Hello ", "text mismatch")
end
test_text_delta()

-- Test error_event constructor
local function test_error_event()
  local e = events.error_event("connection failed")
  assert(e.event_type == "error", "event_type should be error")
  assert(e.error == "connection failed", "error mismatch")
end
test_error_event()

-- Test retry_event constructor
local function test_retry_event()
  local e = events.retry_event(2, 2000, 429, "rate limited")
  assert(e.event_type == "retry", "event_type should be retry")
  assert(e.attempt == 2, "attempt mismatch")
  assert(e.delay_ms == 2000, "delay_ms mismatch")
  assert(e.status == 429, "status mismatch")
  assert(e.error == "rate limited", "error mismatch")
end
test_retry_event()

-- Test to_json serialization
local function test_to_json()
  local e = events.agent_start("claude-sonnet", "test prompt", nil)
  local json_str = events.to_json(e)
  assert(json_str, "should produce JSON string")

  local parsed = json.decode(json_str) as {string:any}
  assert(parsed, "should parse back as valid JSON")
  assert(parsed.event_type == "agent_start", "event_type should survive round-trip")
  assert(parsed.model == "claude-sonnet", "model should survive round-trip")
  assert(parsed.prompt == "test prompt", "prompt should survive round-trip")
end
test_to_json()

-- Test to_json omits nil fields
local function test_to_json_omits_nil()
  local e = events.text_delta("hi")
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string:any}

  -- text_delta should only have event_type, timestamp, text
  assert(parsed.event_type == "text_delta", "should have event_type")
  assert(parsed.text == "hi", "should have text")
  assert(parsed.model == nil, "should not have model")
  assert(parsed.tool_name == nil, "should not have tool_name")
end
test_to_json_omits_nil()

-- Test EventCallback type works as expected
local function test_event_callback()
  local received: {events.EventData} = {}
  local cb: events.EventCallback = function(event: events.EventData)
    table.insert(received, event)
  end

  cb(events.agent_start("model", "prompt", nil))
  cb(events.text_delta("hello"))
  cb(events.agent_end("end_turn"))

  assert(#received == 3, "should receive 3 events")
  assert(received[1].event_type == "agent_start", "first should be agent_start")
  assert(received[2].event_type == "text_delta", "second should be text_delta")
  assert(received[3].event_type == "agent_end", "third should be agent_end")
end
test_event_callback()

-- Test state_change constructor
local function test_state_change()
  local e = events.state_change("idle", "processing")
  assert(e.event_type == "state_change", "event_type should be state_change")
  assert(e.from_state == "idle", "from_state should be idle")
  assert(e.to_state == "processing", "to_state should be processing")
  assert(e.timestamp, "should have timestamp")
end
test_state_change()

-- Test state_change serialization
local function test_state_change_json()
  local e = events.state_change("processing", "idle")
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string:any}
  assert(parsed.event_type == "state_change", "event_type should survive round-trip")
  assert(parsed.from_state == "processing", "from_state should survive round-trip")
  assert(parsed.to_state == "idle", "to_state should survive round-trip")
end
test_state_change_json()

-- Test loop_detected constructor
local function test_loop_detected()
  local e = events.loop_detected(3, "bash:ls|read:/tmp/foo", "warn")
  assert(e.event_type == "loop_detected", "event_type should be loop_detected")
  assert(e.consecutive_count == 3, "consecutive_count should be 3")
  assert(e.turn_signature == "bash:ls|read:/tmp/foo", "turn_signature mismatch")
  assert(e.action == "warn", "action should be warn")
end
test_loop_detected()

-- Test loop_detected break action
local function test_loop_detected_break()
  local e = events.loop_detected(5, "bash:ls", "break")
  assert(e.action == "break", "action should be break")
  assert(e.consecutive_count == 5, "consecutive_count should be 5")
end
test_loop_detected_break()

-- Test loop_detected serialization
local function test_loop_detected_json()
  local e = events.loop_detected(4, "edit:/tmp/file.lua", "warn")
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string:any}
  assert(parsed.event_type == "loop_detected", "event_type should survive round-trip")
  assert(parsed.consecutive_count == 4, "consecutive_count should survive round-trip")
  assert(parsed.turn_signature == "edit:/tmp/file.lua", "turn_signature should survive round-trip")
  assert(parsed.action == "warn", "action should survive round-trip")
end
test_loop_detected_json()

print("all events tests passed")
