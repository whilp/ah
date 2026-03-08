#!/usr/bin/env cosmic
-- test_compact_messages.tl: tests for compaction message sanitization
--
-- The compact() function sends api_messages to the API with no tools defined.
-- If messages contain tool_use blocks (from assistant turns), the API rejects
-- the request. Compaction must sanitize messages first.
--
-- This test file documents and verifies the fix. Until sanitize_for_compaction
-- is implemented, the tests print FAIL to flag the broken behavior.

local compact = require("ah.compact")

-- Access sanitize_for_compaction dynamically to avoid type errors before it exists
local compact_any = compact as {string: any}
local sanitize = compact_any.sanitize_for_compaction as function({any}): {any}

-- Test: api_messages with tool_use blocks need sanitization for compaction
local function test_compact_messages_with_tool_use()
  local api_messages: {any} = {
    {role = "user", content = {{type = "text", text = "hello"}}},
    {role = "assistant", content = {
      {type = "text", text = "I'll check that."},
      {type = "tool_use", id = "tool-1", name = "bash", input = {command = "ls"}},
    }},
    {role = "user", content = {
      {type = "tool_result", tool_use_id = "tool-1", content = "file1.txt\nfile2.txt"},
    }},
    {role = "assistant", content = {
      {type = "text", text = "Here are the files."},
    }},
    {role = "user", content = {{type = "text", text = "thanks"}}},
  }

  if not sanitize then
    print("FAIL sanitize_for_compaction not implemented — compact() sends tool_use blocks without tools defined, which the API rejects")
    return
  end

  local result = sanitize(api_messages)
  local still_has_tool_use = false
  local still_has_tool_result = false
  for _, msg in ipairs(result) do
    local m = msg as {string: any}
    for _, block in ipairs(m.content as {any}) do
      local b = block as {string: any}
      if b.type == "tool_use" then still_has_tool_use = true end
      if b.type == "tool_result" then still_has_tool_result = true end
    end
  end
  assert(not still_has_tool_use, "sanitized messages should not contain tool_use blocks")
  assert(not still_has_tool_result, "sanitized messages should not contain tool_result blocks")

  -- Verify text content is preserved
  local has_hello = false
  local has_check = false
  for _, msg in ipairs(result) do
    local m = msg as {string: any}
    for _, block in ipairs(m.content as {any}) do
      local b = block as {string: any}
      if b.type == "text" then
        if (b.text as string):match("hello") then has_hello = true end
        if (b.text as string):match("check") then has_check = true end
      end
    end
  end
  assert(has_hello, "sanitized messages should preserve user text")
  assert(has_check, "sanitized messages should preserve assistant text")

  -- Verify tool results are converted to text blocks
  local has_tool_output_as_text = false
  for _, msg in ipairs(result) do
    local m = msg as {string: any}
    for _, block in ipairs(m.content as {any}) do
      local b = block as {string: any}
      if b.type == "text" and (b.text as string):match("file1.txt") then
        has_tool_output_as_text = true
      end
    end
  end
  assert(has_tool_output_as_text, "tool result content should be converted to text")

  print("✓ sanitize_for_compaction strips tool blocks and preserves text")
end
test_compact_messages_with_tool_use()

-- Test: messages with only text content pass through unchanged
local function test_compact_messages_text_only()
  if not sanitize then
    print("FAIL sanitize_for_compaction not implemented")
    return
  end

  local api_messages: {any} = {
    {role = "user", content = {{type = "text", text = "hello"}}},
    {role = "assistant", content = {{type = "text", text = "hi there"}}},
    {role = "user", content = {{type = "text", text = "how are you"}}},
  }

  local result = sanitize(api_messages)
  assert(#result == 3, "text-only messages should pass through: got " .. #result)
  print("✓ sanitize_for_compaction preserves text-only messages")
end
test_compact_messages_text_only()

-- Test: tool-only messages are converted to text, not dropped
local function test_compact_messages_tool_only_converted()
  if not sanitize then
    print("FAIL sanitize_for_compaction not implemented")
    return
  end

  local api_messages: {any} = {
    {role = "user", content = {{type = "text", text = "do something"}}},
    {role = "assistant", content = {
      {type = "tool_use", id = "t1", name = "bash", input = {command = "echo hi"}},
    }},
    {role = "user", content = {
      {type = "tool_result", tool_use_id = "t1", content = "hi"},
    }},
  }

  local result = sanitize(api_messages)
  for _, msg in ipairs(result) do
    local m = msg as {string: any}
    assert(#(m.content as {any}) > 0, "no message should be empty after sanitization")
  end
  print("✓ sanitize_for_compaction converts tool-only messages to text")
end
test_compact_messages_tool_only_converted()

-- Test: result has alternating roles (API requirement)
local function test_compact_messages_alternating_roles()
  if not sanitize then
    print("FAIL sanitize_for_compaction not implemented")
    return
  end

  local api_messages: {any} = {
    {role = "user", content = {{type = "text", text = "start"}}},
    {role = "assistant", content = {
      {type = "text", text = "thinking..."},
      {type = "tool_use", id = "t1", name = "read", input = {path = "foo.txt"}},
    }},
    {role = "user", content = {
      {type = "tool_result", tool_use_id = "t1", content = "file contents"},
    }},
    {role = "assistant", content = {
      {type = "text", text = "I see the file."},
    }},
    {role = "user", content = {{type = "text", text = "now what?"}}},
  }

  local result = sanitize(api_messages)
  local last_role: string = nil
  for _, msg in ipairs(result) do
    local m = msg as {string: any}
    if last_role then
      assert(m.role ~= last_role, "messages should alternate roles, got consecutive " .. (m.role as string))
    end
    last_role = m.role as string
  end
  local first = result[1] as {string: any}
  assert(first.role == "user", "first message should be user role")
  print("✓ sanitize_for_compaction maintains alternating roles")
end
test_compact_messages_alternating_roles()

print("\nAll compact message tests completed")
