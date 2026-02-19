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
  -- Unknown model uses default limit (200000)
  assert(compact.needs_compaction(170000, "some-future-model"), "unknown model should use default limit")
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
  assert(compact.DEFAULT_CONTEXT_LIMIT == 200000, "default context limit should be 200000: " .. tostring(compact.DEFAULT_CONTEXT_LIMIT))
  print("✓ DEFAULT_CONTEXT_LIMIT is 200000")
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

print("\nAll compact tests passed!")
