#!/usr/bin/env cosmic
-- test_repair.tl: tests for repair_dangling_tool_use
local loop = require("ah.loop")

local function noop_event(_event: any) end

local function make_assistant_with_tool_use(tool_id: string): {string: any}
  return {
    role = "assistant",
    content = {
      {type = "tool_use", id = tool_id, name = "bash", input = {command = "echo hi"}},
    },
  }
end

local function make_user_with_tool_result(tool_id: string): {string: any}
  return {
    role = "user",
    content = {
      {type = "tool_result", tool_use_id = tool_id, content = "ok"},
    },
  }
end

local function test_repair_single_dangling()
  local msgs: {any} = {
    make_assistant_with_tool_use("id-1"),
  }
  loop.repair_dangling_tool_use(msgs, noop_event)
  assert(#msgs == 2, "should insert one synthetic result: got " .. #msgs)
  local inserted = msgs[2] as {string: any}
  assert(inserted.role == "user", "inserted msg should have role user")
  local content = inserted.content as {any}
  local block = content[1] as {string: any}
  assert(block.type == "tool_result", "block should be tool_result")
  assert(block.tool_use_id == "id-1", "should reference correct tool id")
  assert(block.is_error == true, "should be marked as error")
end
test_repair_single_dangling()

local function test_repair_two_consecutive_dangling()
  -- Two consecutive assistant messages with dangling tool_use blocks (bug case)
  local msgs: {any} = {
    make_assistant_with_tool_use("id-1"),
    make_assistant_with_tool_use("id-2"),
  }
  loop.repair_dangling_tool_use(msgs, noop_event)
  -- Should insert synthetic results for both
  assert(#msgs == 4, "should insert two synthetic results: got " .. #msgs)
  -- Verify each assistant message has a following user tool_result
  for i = 1, 4, 2 do
    local assistant = msgs[i] as {string: any}
    local result_msg = msgs[i + 1] as {string: any}
    assert(assistant.role == "assistant", "index " .. i .. " should be assistant")
    assert(result_msg.role == "user", "index " .. (i + 1) .. " should be user")
    local result_content = result_msg.content as {any}
    local rb = result_content[1] as {string: any}
    assert(rb.type == "tool_result", "index " .. (i + 1) .. " should have tool_result")
  end
end
test_repair_two_consecutive_dangling()

local function test_repair_no_dangling()
  -- Already repaired: assistant + user tool_result
  local msgs: {any} = {
    make_assistant_with_tool_use("id-1"),
    make_user_with_tool_result("id-1"),
  }
  loop.repair_dangling_tool_use(msgs, noop_event)
  assert(#msgs == 2, "should not insert anything: got " .. #msgs)
end
test_repair_no_dangling()

local function test_repair_mixed()
  -- First is properly followed, second is dangling
  local msgs: {any} = {
    make_assistant_with_tool_use("id-1"),
    make_user_with_tool_result("id-1"),
    make_assistant_with_tool_use("id-2"),
  }
  loop.repair_dangling_tool_use(msgs, noop_event)
  assert(#msgs == 4, "should insert one synthetic result: got " .. #msgs)
  local last = msgs[4] as {string: any}
  assert(last.role == "user", "last msg should be user")
  local lc = last.content as {any}
  local lb = lc[1] as {string: any}
  assert(lb.tool_use_id == "id-2", "should reference id-2: got " .. tostring(lb.tool_use_id))
end
test_repair_mixed()

print("all repair_dangling_tool_use tests passed")
