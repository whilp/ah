#!/usr/bin/env cosmic
-- test_compact.tl: tests for context compaction module
local compact = require("ah.compact")

-- get_context_limit tests

local function test_get_context_limit_sonnet()
  local limit = compact.get_context_limit("claude-sonnet-4-6")
  assert(limit == 1000000, "sonnet 4.6 context limit should be 1000000: " .. tostring(limit))
  print("✓ get_context_limit known model (sonnet 4.6)")
end
test_get_context_limit_sonnet()

local function test_get_context_limit_opus()
  local limit = compact.get_context_limit("claude-opus-4-6")
  assert(limit == 1000000, "opus 4.6 context limit should be 1000000: " .. tostring(limit))
  print("✓ get_context_limit known model (opus 4.6)")
end
test_get_context_limit_opus()

local function test_get_context_limit_opus_45()
  local limit = compact.get_context_limit("claude-opus-4-5-20251101")
  assert(limit == 200000, "opus 4.5 context limit should be 200000: " .. tostring(limit))
  print("✓ get_context_limit known model (opus 4.5)")
end
test_get_context_limit_opus_45()

local function test_get_context_limit_haiku()
  local limit = compact.get_context_limit("claude-haiku-4-5-20251001")
  assert(limit == 200000, "haiku context limit should be 200000: " .. tostring(limit))
  print("✓ get_context_limit known model (haiku)")
end
test_get_context_limit_haiku()

local function test_get_context_limit_unknown_model()
  local limit = compact.get_context_limit("unknown-model-v1")
  assert(limit == compact.DEFAULT_CONTEXT_LIMIT, "unknown model should use default limit")
  print("✓ get_context_limit unknown model")
end
test_get_context_limit_unknown_model()

local function test_get_context_limit_nil_model()
  local limit = compact.get_context_limit(nil)
  assert(limit == compact.DEFAULT_CONTEXT_LIMIT, "nil model should use default limit")
  print("✓ get_context_limit nil model")
end
test_get_context_limit_nil_model()

-- needs_compaction tests

local function test_needs_compaction_nil_tokens()
  assert(not compact.needs_compaction(nil, "claude-sonnet-4-6"), "nil tokens should not trigger compaction")
  print("✓ needs_compaction nil tokens")
end
test_needs_compaction_nil_tokens()

local function test_needs_compaction_zero_tokens()
  assert(not compact.needs_compaction(0, "claude-sonnet-4-6"), "zero tokens should not trigger compaction")
  print("✓ needs_compaction zero tokens")
end
test_needs_compaction_zero_tokens()

local function test_needs_compaction_below_threshold()
  -- sonnet 4.6 has 1M context, threshold 0.8 = 800000
  assert(not compact.needs_compaction(500000, "claude-sonnet-4-6"), "500k should not trigger compaction for 1M model")
  print("✓ needs_compaction below threshold")
end
test_needs_compaction_below_threshold()

local function test_needs_compaction_above_threshold()
  -- sonnet 4.6 has 1M context, threshold 0.8 = 800000
  assert(compact.needs_compaction(850000, "claude-sonnet-4-6"), "850k should trigger compaction for 1M model")
  print("✓ needs_compaction above threshold")
end
test_needs_compaction_above_threshold()

local function test_needs_compaction_at_boundary()
  -- exactly at 0.8 * 1000000 = 800000
  assert(not compact.needs_compaction(800000, "claude-sonnet-4-6"), "exactly 0.8 ratio should not trigger")
  assert(compact.needs_compaction(800001, "claude-sonnet-4-6"), "just over 0.8 ratio should trigger")
  print("✓ needs_compaction at boundary")
end
test_needs_compaction_at_boundary()

local function test_needs_compaction_haiku()
  -- haiku has 200k context, threshold 0.8 = 160000
  assert(compact.needs_compaction(160001, "claude-haiku-4-5-20251001"), "160001/200000 should trigger compaction")
  assert(not compact.needs_compaction(150000, "claude-haiku-4-5-20251001"), "150000/200000 should not trigger")
  print("✓ needs_compaction haiku model")
end
test_needs_compaction_haiku()

local function test_needs_compaction_custom_threshold_low()
  -- Custom threshold of 0.5 (50%) for haiku (200k)
  assert(compact.needs_compaction(110000, "claude-haiku-4-5-20251001", 0.5), "110k at 0.5 threshold for 200k should trigger")
  assert(not compact.needs_compaction(80000, "claude-haiku-4-5-20251001", 0.5), "80k at 0.5 threshold for 200k should not trigger")
  print("✓ needs_compaction custom threshold (low)")
end
test_needs_compaction_custom_threshold_low()

local function test_needs_compaction_custom_threshold_tight()
  -- Custom threshold of 0.9 (90%) for 1M model
  assert(not compact.needs_compaction(850000, "claude-sonnet-4-6", 0.9), "850k at 0.9 threshold for 1M should not trigger")
  assert(compact.needs_compaction(950000, "claude-sonnet-4-6", 0.9), "950k at 0.9 threshold for 1M should trigger")
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

print("all compact tests passed")
