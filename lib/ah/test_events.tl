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
  local e = events.agent_end("end_turn", 1000, 500, nil, nil)
  assert(e.event_type == "agent_end", "event_type should be agent_end")
  assert(e.stop_reason == "end_turn", "stop_reason mismatch")
  assert(e.total_input_tokens == 1000, "total_input_tokens mismatch")
  assert(e.total_output_tokens == 500, "total_output_tokens mismatch")
  assert(e.error == nil, "error should be nil for normal end")
end
test_agent_end()

-- Test agent_end without token totals (nil)
local function test_agent_end_no_tokens()
  local e = events.agent_end("interrupted", nil, nil, nil, nil)
  assert(e.event_type == "agent_end", "event_type should be agent_end")
  assert(e.stop_reason == "interrupted", "stop_reason mismatch")
  assert(e.total_input_tokens == nil, "total_input_tokens should be nil")
  assert(e.total_output_tokens == nil, "total_output_tokens should be nil")
end
test_agent_end_no_tokens()

-- Test agent_end with error message
local function test_agent_end_with_error()
  local e = events.agent_end("error", 500, 100, "API error 401: unauthorized", nil)
  assert(e.event_type == "agent_end", "event_type should be agent_end")
  assert(e.stop_reason == "error", "stop_reason should be error")
  assert(e.error == "API error 401: unauthorized", "error mismatch")
  assert(e.total_input_tokens == 500, "total_input_tokens mismatch")
end
test_agent_end_with_error()

-- Test api_call_start constructor
local function test_api_call_start()
  local e = events.api_call_start(12345)
  assert(e.event_type == "api_call_start", "event_type should be api_call_start")
  assert(e.timestamp, "should have timestamp")
  assert(e.payload_bytes == 12345, "payload_bytes should be set")
end
test_api_call_start()

-- Test api_call_end constructor
local function test_api_call_end()
  local e = events.api_call_end("msg123", 100, 50, 1500, "claude-sonnet", 0, 0)
  assert(e.event_type == "api_call_end", "event_type should be api_call_end")
  assert(e.message_id == "msg123", "message_id mismatch")
  assert(e.input_tokens == 100, "input_tokens mismatch")
  assert(e.output_tokens == 50, "output_tokens mismatch")
  assert(e.api_latency_ms == 1500, "api_latency_ms mismatch")
  assert(e.model == "claude-sonnet", "model mismatch")
  assert(e.cache_creation_input_tokens == 0, "cache_creation should be 0")
  assert(e.cache_read_input_tokens == 0, "cache_read should be 0")
end
test_api_call_end()

-- Test api_call_end with cache tokens
local function test_api_call_end_cache()
  local e = events.api_call_end("msg456", 5000, 200, 800, "claude-sonnet", 3000, 1500)
  assert(e.cache_creation_input_tokens == 3000, "cache_creation_input_tokens mismatch")
  assert(e.cache_read_input_tokens == 1500, "cache_read_input_tokens mismatch")
  assert(e.input_tokens == 5000, "input_tokens should still be set")
end
test_api_call_end_cache()

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

  local parsed = json.decode(json_str) as {string: any}
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
  local parsed = json.decode(json_str) as {string: any}

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
  cb(events.agent_end("end_turn", nil, nil, nil, nil))

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
  local parsed = json.decode(json_str) as {string: any}
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
  local parsed = json.decode(json_str) as {string: any}
  assert(parsed.event_type == "loop_detected", "event_type should survive round-trip")
  assert(parsed.consecutive_count == 4, "consecutive_count should survive round-trip")
  assert(parsed.turn_signature == "edit:/tmp/file.lua", "turn_signature should survive round-trip")
  assert(parsed.action == "warn", "action should survive round-trip")
end
test_loop_detected_json()

-- Test budget_exceeded constructor
local function test_budget_exceeded()
  local e = events.budget_exceeded(50000, 10000, 40000)
  assert(e.event_type == "budget_exceeded", "event_type should be budget_exceeded")
  assert(e.total_input_tokens == 50000, "total_input_tokens mismatch")
  assert(e.total_output_tokens == 10000, "total_output_tokens mismatch")
  assert(e.max_tokens == 40000, "max_tokens mismatch")
end
test_budget_exceeded()

-- Test budget_exceeded serialization
local function test_budget_exceeded_json()
  local e = events.budget_exceeded(100000, 25000, 120000)
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string: any}
  assert(parsed.event_type == "budget_exceeded", "event_type should survive round-trip")
  assert(parsed.total_input_tokens == 100000, "total_input_tokens should survive round-trip")
  assert(parsed.total_output_tokens == 25000, "total_output_tokens should survive round-trip")
  assert(parsed.max_tokens == 120000, "max_tokens should survive round-trip")
end
test_budget_exceeded_json()

-- Test steering_received constructor
local function test_steering_received()
  local e = events.steering_received("please stop", 2)
  assert(e.event_type == "steering_received", "event_type should be steering_received")
  assert(e.content == "please stop", "content mismatch")
  assert(e.message_count == 2, "message_count mismatch")
  assert(e.timestamp, "should have timestamp")
end
test_steering_received()

-- Test steering_received serialization
local function test_steering_received_json()
  local e = events.steering_received("change direction", 1)
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string: any}
  assert(parsed.event_type == "steering_received", "event_type should survive round-trip")
  assert(parsed.content == "change direction", "content should survive round-trip")
  assert(parsed.message_count == 1, "message_count should survive round-trip")
end
test_steering_received_json()

-- Test followup_received constructor
local function test_followup_received()
  local e = events.followup_received("do this next", 3)
  assert(e.event_type == "followup_received", "event_type should be followup_received")
  assert(e.content == "do this next", "content mismatch")
  assert(e.message_count == 3, "message_count mismatch")
  assert(e.timestamp, "should have timestamp")
end
test_followup_received()

-- Test followup_received serialization
local function test_followup_received_json()
  local e = events.followup_received("follow up task", 1)
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string: any}
  assert(parsed.event_type == "followup_received", "event_type should survive round-trip")
  assert(parsed.content == "follow up task", "content should survive round-trip")
end
test_followup_received_json()

-- Test compaction_triggered constructor
local function test_compaction_triggered()
  local e = events.compaction_triggered(170000, 200000)
  assert(e.event_type == "compaction_triggered", "event_type should be compaction_triggered")
  assert(e.input_tokens == 170000, "input_tokens mismatch")
  assert(e.context_limit == 200000, "context_limit mismatch")
end
test_compaction_triggered()

-- Test compaction_triggered serialization
local function test_compaction_triggered_json()
  local e = events.compaction_triggered(180000, 200000)
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string: any}
  assert(parsed.event_type == "compaction_triggered", "event_type should survive round-trip")
  assert(parsed.input_tokens == 180000, "input_tokens should survive round-trip")
  assert(parsed.context_limit == 200000, "context_limit should survive round-trip")
end
test_compaction_triggered_json()

-- Test compaction_complete constructor
local function test_compaction_complete()
  local e = events.compaction_complete(180000, 2000)
  assert(e.event_type == "compaction_complete", "event_type should be compaction_complete")
  assert(e.input_tokens == 180000, "input_tokens mismatch")
  assert(e.output_tokens == 2000, "output_tokens mismatch")
end
test_compaction_complete()

-- Test compaction_complete serialization
local function test_compaction_complete_json()
  local e = events.compaction_complete(150000, 3000)
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string: any}
  assert(parsed.event_type == "compaction_complete", "event_type should survive round-trip")
  assert(parsed.input_tokens == 150000, "input_tokens should survive round-trip")
  assert(parsed.output_tokens == 3000, "output_tokens should survive round-trip")
end
test_compaction_complete_json()

-- Test payload_warn constructor
local function test_payload_warn()
  local e = events.payload_warn(900000, 800000)
  assert(e.event_type == "payload_warn", "event_type should be payload_warn")
  assert(e.payload_bytes == 900000, "payload_bytes mismatch")
  assert(e.threshold == 800000, "threshold mismatch")
end
test_payload_warn()

-- Test payload_warn serialization
local function test_payload_warn_json()
  local e = events.payload_warn(1024000, 800000)
  local json_str = events.to_json(e)
  local parsed = json.decode(json_str) as {string: any}
  assert(parsed.event_type == "payload_warn", "event_type should survive round-trip")
  assert(parsed.payload_bytes == 1024000, "payload_bytes should survive round-trip")
  assert(parsed.threshold == 800000, "threshold should survive round-trip")
end
test_payload_warn_json()

print("all events tests passed")
