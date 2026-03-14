#!/usr/bin/env cosmic
-- test_compact.tl: tests for context compaction module
local compact = require("ah.compact")

-- get_context_limit tests

local function test_get_context_limit_known_model()
  local limit = compact.get_context_limit("claude-sonnet-4-6")
  assert(limit == 200000, "sonnet context limit should be 200000: " .. tostring(limit))
  print("✓ get_context_limit known model (sonnet)")
end
test_get_context_limit_known_model()

local function test_get_context_limit_sonnet_46()
  local limit = compact.get_context_limit("claude-sonnet-4-6")
  assert(limit == 200000, "sonnet 4.6 context limit should be 200000: " .. tostring(limit))
  print("✓ get_context_limit known model (sonnet 4.6)")
end
test_get_context_limit_sonnet_46()

local function test_get_context_limit_sonnet_46_1m()
  local limit = compact.get_context_limit("claude-sonnet-4-6-1m")
  assert(limit == 1000000, "sonnet 4.6 1m context limit should be 1000000: " .. tostring(limit))
  print("✓ get_context_limit known model (sonnet 4.6 1m)")
end
test_get_context_limit_sonnet_46_1m()

local function test_get_context_limit_opus()
  local limit = compact.get_context_limit("claude-opus-4-6")
  assert(limit == 200000, "opus 4.6 context limit should be 200000: " .. tostring(limit))
  print("✓ get_context_limit known model (opus 4.6)")
end
test_get_context_limit_opus()

local function test_get_context_limit_opus_1m()
  local limit = compact.get_context_limit("claude-opus-4-6-1m")
  assert(limit == 1000000, "opus 4.6 1m context limit should be 1000000: " .. tostring(limit))
  print("✓ get_context_limit known model (opus 4.6 1m)")
end
test_get_context_limit_opus_1m()

local function test_get_context_limit_haiku()
  local limit = compact.get_context_limit("claude-haiku-4-5-20251001")
  assert(limit == 200000, "haiku context limit should be 200000: " .. tostring(limit))
  print("✓ get_context_limit known model (haiku)")
end
test_get_context_limit_haiku()

local function test_get_context_limit_unknown_model()
  local limit = compact.get_context_limit("unknown-model-v1")
  assert(limit == compact.DEFAULT_CONTEXT_LIMIT, "unknown model should use default: " .. tostring(limit))
  print("✓ get_context_limit unknown model")
end
test_get_context_limit_unknown_model()

local function test_get_context_limit_nil_model()
  local limit = compact.get_context_limit(nil)
  assert(limit == compact.DEFAULT_CONTEXT_LIMIT, "nil model should use default: " .. tostring(limit))
  print("✓ get_context_limit nil model")
end
test_get_context_limit_nil_model()

-- needs_compaction tests

local function test_needs_compaction_below_threshold()
  -- 50% of 200k = 100k tokens
  assert(not compact.needs_compaction(100000, "claude-sonnet-4-6"), "100k/200k should not trigger compaction")
  print("✓ needs_compaction below threshold")
end
test_needs_compaction_below_threshold()

local function test_needs_compaction_at_threshold()
  -- Exactly at 80% = 160k tokens (0.8 is not > 0.8)
  assert(not compact.needs_compaction(160000, "claude-sonnet-4-6"), "exactly at threshold should not trigger")
  print("✓ needs_compaction at threshold boundary")
end
test_needs_compaction_at_threshold()

local function test_needs_compaction_above_threshold()
  -- 85% = 170k tokens
  assert(compact.needs_compaction(170000, "claude-sonnet-4-6"), "170k/200k should trigger compaction")
  print("✓ needs_compaction above threshold")
end
test_needs_compaction_above_threshold()

local function test_needs_compaction_just_above_threshold()
  -- 80.1% = 160001 tokens
  assert(compact.needs_compaction(160001, "claude-sonnet-4-6"), "160001/200000 should trigger compaction")
  print("✓ needs_compaction just above threshold")
end
test_needs_compaction_just_above_threshold()

local function test_needs_compaction_zero_tokens()
  assert(not compact.needs_compaction(0, "claude-sonnet-4-6"), "zero tokens should not trigger")
  print("✓ needs_compaction zero tokens")
end
test_needs_compaction_zero_tokens()

local function test_needs_compaction_custom_threshold_low()
  -- 60% of 200k = 120k tokens, custom threshold 0.5
  assert(compact.needs_compaction(120000, "claude-sonnet-4-6", 0.5), "120k at 0.5 threshold should trigger")
  print("✓ needs_compaction custom threshold (triggers)")
end
test_needs_compaction_custom_threshold_low()

local function test_needs_compaction_custom_threshold_high()
  -- 80k at 0.5 threshold = 40% < 50%
  assert(not compact.needs_compaction(80000, "claude-sonnet-4-6", 0.5), "80k at 0.5 threshold should not trigger")
  print("✓ needs_compaction custom threshold (no trigger)")
end
test_needs_compaction_custom_threshold_high()

local function test_needs_compaction_custom_threshold_tight()
  -- Custom threshold of 0.9 (90%)
  assert(not compact.needs_compaction(170000, "claude-sonnet-4-6", 0.9), "170k at 0.9 threshold should not trigger")
  assert(compact.needs_compaction(190000, "claude-sonnet-4-6", 0.9), "190k at 0.9 threshold should trigger")
  print("✓ needs_compaction custom threshold (tight)")
end
test_needs_compaction_custom_threshold_tight()

local function test_needs_compaction_unknown_model()
  -- Unknown model uses default limit (1000000), threshold 0.8 = 800000
  assert(compact.needs_compaction(850000, "some-future-model"), "unknown model should use default limit")
  assert(not compact.needs_compaction(170000, "some-future-model"), "170k should not trigger with 1M default limit")
  print("✓ needs_compaction with unknown model")
end
test_needs_compaction_unknown_model()

-- Constants tests

local function test_default_threshold()
  assert(compact.DEFAULT_THRESHOLD == 0.8, "default threshold should be 0.8: " .. tostring(compact.DEFAULT_THRESHOLD))
  print("✓ DEFAULT_THRESHOLD is 0.8")
end
test_default_threshold()

local function test_default_context_limit()
  assert(compact.DEFAULT_CONTEXT_LIMIT == 1000000, "default context limit should be 1000000: " .. tostring(compact.DEFAULT_CONTEXT_LIMIT))
  print("✓ DEFAULT_CONTEXT_LIMIT is 1000000")
end
test_default_context_limit()

local function test_compaction_prompt_exists()
  assert(compact.COMPACTION_SYSTEM_PROMPT and #compact.COMPACTION_SYSTEM_PROMPT > 0, "compaction prompt should exist and be non-empty")
  print("✓ COMPACTION_SYSTEM_PROMPT exists")
end
test_compaction_prompt_exists()

local function test_compaction_prompt_content()
  local prompt = compact.COMPACTION_SYSTEM_PROMPT
  assert(prompt:match("accomplished"), "prompt should mention what was accomplished")
  assert(prompt:match("work in progress"), "prompt should mention work in progress")
  assert(prompt:match("Files"), "prompt should mention files")
  assert(prompt:match("next steps"), "prompt should mention next steps")
  print("✓ COMPACTION_SYSTEM_PROMPT contains key instructions")
end
test_compaction_prompt_content()

local function test_model_limits_all_present()
  assert(compact.MODEL_CONTEXT_LIMITS["claude-sonnet-4-6"], "sonnet should have a limit")
  assert(compact.MODEL_CONTEXT_LIMITS["claude-sonnet-4-6-1m"], "sonnet 4.6 1m should have a limit")
  assert(compact.MODEL_CONTEXT_LIMITS["claude-opus-4-6"], "opus should have a limit")
  assert(compact.MODEL_CONTEXT_LIMITS["claude-opus-4-6-1m"], "opus 1m should have a limit")
  assert(compact.MODEL_CONTEXT_LIMITS["claude-haiku-4-5-20251001"], "haiku should have a limit")
  print("✓ all models have context limits")
end
test_model_limits_all_present()

-- sanitize_for_compaction tests

local function test_sanitize_text_only_passthrough()
  local msgs = {
    {role = "user", content = {{type = "text", text = "hello"}}},
    {role = "assistant", content = {{type = "text", text = "world"}}},
  }
  local result = compact.sanitize_for_compaction(msgs)
  assert(#result == 2, "should preserve two messages: " .. tostring(#result))
  local m1 = result[1] as {string: any}
  assert(m1.role == "user", "first message should be user")
  local c1 = m1.content as {any}
  assert(#c1 == 1, "first message should have one block")
  local b1 = c1[1] as {string: any}
  assert(b1.type == "text", "block type should be text")
  assert(b1.text == "hello", "text should be preserved")
  print("✓ sanitize_for_compaction: text-only messages pass through unchanged")
end
test_sanitize_text_only_passthrough()

local function test_sanitize_tool_use_converted_to_text()
  local tool_block: {string: any} = {type = "tool_use", id = "tu1", name = "bash", input = {command = "ls -la"}}
  local msgs: {any} = {
    {role = "user", content = {{type = "text", text = "run this"}}},
    {role = "assistant", content = {tool_block as any}},
  }
  local result = compact.sanitize_for_compaction(msgs)
  assert(#result == 2, "should have two messages: " .. tostring(#result))
  local assistant = result[2] as {string: any}
  assert(assistant.role == "assistant", "second message should be assistant")
  local content = assistant.content as {any}
  assert(#content == 1, "should have one block: " .. tostring(#content))
  local block = content[1] as {string: any}
  assert(block.type == "text", "block should be text type")
  local text = block.text as string
  assert(text:find("Tool: bash"), "text should contain tool name: " .. text)
  assert(text:find("ls %-la"), "text should contain command: " .. text)
  print("✓ sanitize_for_compaction: tool_use block converted to text")
end
test_sanitize_tool_use_converted_to_text()

local function test_sanitize_tool_result_string_converted_to_text()
  local result_block: {string: any} = {type = "tool_result", tool_use_id = "tu1", content = "output here"}
  local msgs: {any} = {
    {role = "user", content = {result_block as any}},
  }
  local result = compact.sanitize_for_compaction(msgs)
  assert(#result == 1, "should have one message")
  local m = result[1] as {string: any}
  local content = m.content as {any}
  local block = content[1] as {string: any}
  assert(block.type == "text", "block should be text type")
  local text = block.text as string
  assert(text:find("Tool result: tu1"), "text should contain tool_use_id: " .. text)
  assert(text:find("output here"), "text should contain output: " .. text)
  print("✓ sanitize_for_compaction: tool_result (string) converted to text")
end
test_sanitize_tool_result_string_converted_to_text()

local function test_sanitize_tool_result_array_converted_to_text()
  local inner_blocks: {any} = {
    {type = "text", text = "line one"},
    {type = "text", text = "line two"},
  }
  local result_block: {string: any} = {type = "tool_result", tool_use_id = "tu2", content = inner_blocks}
  local msgs: {any} = {
    {role = "user", content = {result_block as any}},
  }
  local result = compact.sanitize_for_compaction(msgs)
  assert(#result == 1, "should have one message")
  local m = result[1] as {string: any}
  local content = m.content as {any}
  local block = content[1] as {string: any}
  assert(block.type == "text", "block should be text type")
  local text = block.text as string
  assert(text:find("Tool result: tu2"), "text should contain tool_use_id: " .. text)
  assert(text:find("line one"), "text should contain first line: " .. text)
  assert(text:find("line two"), "text should contain second line: " .. text)
  print("✓ sanitize_for_compaction: tool_result (array) converted to text")
end
test_sanitize_tool_result_array_converted_to_text()

local function test_sanitize_consecutive_same_role_merged()
  -- tool_use (assistant) followed by tool_result (user) then another user text
  -- After sanitization both user messages should be merged
  local tool_use: {string: any} = {type = "tool_use", id = "tu1", name = "bash", input = {command = "ls"}}
  local tool_result: {string: any} = {type = "tool_result", tool_use_id = "tu1", content = "file1"}
  local msgs: {any} = {
    {role = "user", content = {{type = "text", text = "start"}}},
    {role = "assistant", content = {tool_use as any}},
    {role = "user", content = {tool_result as any}},
    {role = "user", content = {{type = "text", text = "extra user msg"}}},
  }
  local result = compact.sanitize_for_compaction(msgs)
  -- user, assistant, user+user merged = 3 messages
  assert(#result == 3, "should have 3 messages after merge: " .. tostring(#result))
  local last = result[3] as {string: any}
  assert(last.role == "user", "last message should be user")
  local content = last.content as {any}
  assert(#content == 2, "merged user message should have 2 blocks: " .. tostring(#content))
  print("✓ sanitize_for_compaction: consecutive same-role messages merged")
end
test_sanitize_consecutive_same_role_merged()

local function test_sanitize_empty_messages_removed()
  -- A message with empty content (e.g. after stripping tool blocks with no text)
  -- should not appear in the output
  local msgs: {any} = {
    {role = "user", content = {}},
    {role = "assistant", content = {{type = "text", text = "hello"}}},
  }
  local result = compact.sanitize_for_compaction(msgs)
  assert(#result == 1, "empty message should be removed: " .. tostring(#result))
  local m = result[1] as {string: any}
  assert(m.role == "assistant", "remaining message should be assistant")
  print("✓ sanitize_for_compaction: empty messages removed")
end
test_sanitize_empty_messages_removed()

local function test_sanitize_mixed_conversation()
  -- Full turn: user text → assistant text + tool_use → user tool_result → assistant text
  local tool_use: {string: any} = {type = "tool_use", id = "tu1", name = "bash", input = {command = "echo hi"}}
  local tool_result: {string: any} = {type = "tool_result", tool_use_id = "tu1", content = "hi"}
  local msgs: {any} = {
    {role = "user", content = {{type = "text", text = "hello"}}},
    {role = "assistant", content = {{type = "text", text = "I will run bash"}, tool_use as any}},
    {role = "user", content = {tool_result as any}},
    {role = "assistant", content = {{type = "text", text = "done"}}},
  }
  local result = compact.sanitize_for_compaction(msgs)
  assert(#result == 4, "should have 4 messages: " .. tostring(#result))
  local m1 = result[1] as {string: any}
  assert(m1.role == "user")
  local m2 = result[2] as {string: any}
  assert(m2.role == "assistant")
  local m2c = m2.content as {any}
  assert(#m2c == 2, "assistant should have 2 blocks (text + converted tool_use): " .. tostring(#m2c))
  local m3 = result[3] as {string: any}
  assert(m3.role == "user")
  local m4 = result[4] as {string: any}
  assert(m4.role == "assistant")
  print("✓ sanitize_for_compaction: mixed conversation produces valid alternating structure")
end
test_sanitize_mixed_conversation()

print("\nAll compact tests passed!")
