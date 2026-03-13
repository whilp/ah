#!/usr/bin/env cosmic
-- test_work.tl: tests for work skill library (metric parsing, state, comparison)
local work = require("ah.work")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/test_work"
fs.makedirs(tmpdir)

-- ==========================================================================
-- parse_metrics: extract METRIC name=value lines from command output
-- ==========================================================================

local function test_parse_metrics_basic()
  local metrics = work.parse_metrics("METRIC time=1234\nMETRIC mem=567\n")
  assert(metrics.time == 1234, "expected time=1234, got: " .. tostring(metrics.time))
  assert(metrics.mem == 567, "expected mem=567, got: " .. tostring(metrics.mem))
  print("✓ parse_metrics basic")
end
test_parse_metrics_basic()

local function test_parse_metrics_float()
  local metrics = work.parse_metrics("METRIC bpb=1.234\n")
  assert(metrics.bpb == 1.234, "expected bpb=1.234, got: " .. tostring(metrics.bpb))
  print("✓ parse_metrics float")
end
test_parse_metrics_float()

local function test_parse_metrics_negative()
  local metrics = work.parse_metrics("METRIC delta=-42.5\n")
  assert(metrics.delta == -42.5, "expected delta=-42.5, got: " .. tostring(metrics.delta))
  print("✓ parse_metrics negative")
end
test_parse_metrics_negative()

local function test_parse_metrics_mixed_output()
  local output = "Building...\nok\nMETRIC time=500\nsome other output\nMETRIC size=200\ndone\n"
  local metrics = work.parse_metrics(output)
  assert(metrics.time == 500, "expected time=500")
  assert(metrics.size == 200, "expected size=200")
  print("✓ parse_metrics mixed output")
end
test_parse_metrics_mixed_output()

local function test_parse_metrics_no_metrics()
  local metrics = work.parse_metrics("no metrics here\njust output\n")
  assert(next(metrics) == nil, "expected empty metrics")
  print("✓ parse_metrics no metrics")
end
test_parse_metrics_no_metrics()

local function test_parse_metrics_empty()
  local metrics = work.parse_metrics("")
  assert(next(metrics) == nil, "expected empty metrics for empty string")
  print("✓ parse_metrics empty")
end
test_parse_metrics_empty()

local function test_parse_metrics_duplicate_last_wins()
  local metrics = work.parse_metrics("METRIC x=1\nMETRIC x=2\n")
  assert(metrics.x == 2, "expected last value to win, got: " .. tostring(metrics.x))
  print("✓ parse_metrics duplicate last wins")
end
test_parse_metrics_duplicate_last_wins()

-- ==========================================================================
-- is_better: compare metrics with direction
-- ==========================================================================

local function test_is_better_lower()
  assert(work.is_better(90, 100, "lower") == true, "90 < 100 should be better when lower")
  assert(work.is_better(100, 90, "lower") == false, "100 > 90 should not be better when lower")
  assert(work.is_better(100, 100, "lower") == false, "equal should not be better")
  print("✓ is_better lower")
end
test_is_better_lower()

local function test_is_better_higher()
  assert(work.is_better(100, 90, "higher") == true, "100 > 90 should be better when higher")
  assert(work.is_better(90, 100, "higher") == false, "90 < 100 should not be better when higher")
  assert(work.is_better(100, 100, "higher") == false, "equal should not be better")
  print("✓ is_better higher")
end
test_is_better_higher()

-- ==========================================================================
-- format_comparison: produce human-readable comparison string
-- ==========================================================================

local function test_format_comparison_improvement()
  local s = work.format_comparison(90, 100, "lower")
  assert(s:find("10%.0%%"), "expected 10.0%% improvement, got: " .. s)
  assert(s:find("better") or s:find("improved"), "should indicate improvement: " .. s)
  print("✓ format_comparison improvement")
end
test_format_comparison_improvement()

local function test_format_comparison_regression()
  local s = work.format_comparison(110, 100, "lower")
  assert(s:find("10%.0%%"), "expected 10.0%% regression, got: " .. s)
  assert(s:find("worse") or s:find("regress"), "should indicate regression: " .. s)
  print("✓ format_comparison regression")
end
test_format_comparison_regression()

local function test_format_comparison_equal()
  local s = work.format_comparison(100, 100, "lower")
  assert(s:find("no change") or s:find("equal") or s:find("same"), "should indicate no change: " .. s)
  print("✓ format_comparison equal")
end
test_format_comparison_equal()

-- ==========================================================================
-- load_state / append_config / append_result: JSONL state management
-- ==========================================================================

local function test_load_state_empty()
  local state = work.load_state(fs.join(tmpdir, "nonexistent.jsonl"))
  assert(#state.results == 0, "expected empty results")
  assert(state.config == nil, "expected nil config for empty state")
  print("✓ load_state empty")
end
test_load_state_empty()

local function test_append_config_and_load()
  local path = fs.join(tmpdir, "test_config.jsonl")
  os.remove(path)
  work.append_config(path, {
    name = "test-session",
    metric_name = "time",
    metric_unit = "ms",
    direction = "lower",
  })
  local state = work.load_state(path)
  assert(state.config ~= nil, "config should be loaded")
  assert(state.config.name == "test-session", "name mismatch: " .. tostring(state.config.name))
  assert(state.config.metric_name == "time", "metric_name mismatch")
  assert(state.config.metric_unit == "ms", "metric_unit mismatch")
  assert(state.config.direction == "lower", "direction mismatch")
  assert(#state.results == 0, "should have no results yet")
  print("✓ append_config and load")
end
test_append_config_and_load()

local function test_append_result_and_load()
  local path = fs.join(tmpdir, "test_results.jsonl")
  os.remove(path)
  work.append_config(path, {
    name = "test",
    metric_name = "time",
    metric_unit = "ms",
    direction = "lower",
  })
  work.append_result(path, {
    metric = 100,
    metrics = {compile = 50, render = 50},
    status = "keep",
    description = "baseline",
  })
  work.append_result(path, {
    metric = 90,
    metrics = {compile = 45, render = 45},
    status = "keep",
    description = "optimized foo",
  })
  work.append_result(path, {
    metric = 110,
    metrics = {},
    status = "discard",
    description = "bad idea",
  })
  local state = work.load_state(path)
  assert(#state.results == 3, "expected 3 results, got: " .. #state.results)
  assert(state.results[1].metric == 100, "first result metric")
  assert(state.results[1].status == "keep", "first result status")
  assert(state.results[2].metric == 90, "second result metric")
  assert(state.results[3].status == "discard", "third result status")
  assert(state.results[1].metrics.compile == 50, "first result secondary metric")
  print("✓ append_result and load")
end
test_append_result_and_load()

local function test_load_state_skips_malformed()
  local path = fs.join(tmpdir, "test_malformed.jsonl")
  os.remove(path)
  cio.barf(path, '{"type":"config","name":"test","metric_name":"x","direction":"lower"}\nnot json\n{"metric":42,"status":"keep","description":"ok"}\n')
  local state = work.load_state(path)
  assert(state.config ~= nil, "config should load")
  assert(#state.results == 1, "should skip malformed line, got: " .. #state.results)
  assert(state.results[1].metric == 42, "should load valid result")
  print("✓ load_state skips malformed lines")
end
test_load_state_skips_malformed()

-- ==========================================================================
-- best_result: find best kept result
-- ==========================================================================

local function test_best_result()
  local path = fs.join(tmpdir, "test_best.jsonl")
  os.remove(path)
  work.append_config(path, {
    name = "test",
    metric_name = "time",
    metric_unit = "ms",
    direction = "lower",
  })
  work.append_result(path, {metric = 100, metrics = {}, status = "keep", description = "baseline"})
  work.append_result(path, {metric = 80, metrics = {}, status = "keep", description = "good"})
  work.append_result(path, {metric = 70, metrics = {}, status = "discard", description = "discarded"})
  work.append_result(path, {metric = 90, metrics = {}, status = "keep", description = "ok"})

  local state = work.load_state(path)
  local best = work.best_result(state)
  assert(best ~= nil, "should find a best result")
  assert(best.metric == 80, "best kept should be 80, got: " .. tostring(best.metric))
  assert(best.description == "good", "best description should be 'good'")
  print("✓ best_result")
end
test_best_result()

local function test_best_result_higher()
  local path = fs.join(tmpdir, "test_best_higher.jsonl")
  os.remove(path)
  work.append_config(path, {
    name = "test",
    metric_name = "score",
    metric_unit = "",
    direction = "higher",
  })
  work.append_result(path, {metric = 50, metrics = {}, status = "keep", description = "baseline"})
  work.append_result(path, {metric = 80, metrics = {}, status = "keep", description = "good"})
  work.append_result(path, {metric = 90, metrics = {}, status = "discard", description = "discarded"})

  local state = work.load_state(path)
  local best = work.best_result(state)
  assert(best ~= nil, "should find a best result")
  assert(best.metric == 80, "best kept should be 80 (highest kept), got: " .. tostring(best.metric))
  print("✓ best_result higher direction")
end
test_best_result_higher()

local function test_best_result_no_keeps()
  local path = fs.join(tmpdir, "test_best_nokeep.jsonl")
  os.remove(path)
  work.append_config(path, {
    name = "test",
    metric_name = "time",
    metric_unit = "",
    direction = "lower",
  })
  work.append_result(path, {metric = 100, metrics = {}, status = "discard", description = "bad"})

  local state = work.load_state(path)
  local best = work.best_result(state)
  assert(best == nil, "should return nil when no keeps")
  print("✓ best_result no keeps")
end
test_best_result_no_keeps()

-- ==========================================================================
-- format_summary: produce a human-readable summary of state
-- ==========================================================================

local function test_format_summary()
  local path = fs.join(tmpdir, "test_summary.jsonl")
  os.remove(path)
  work.append_config(path, {
    name = "test",
    metric_name = "time",
    metric_unit = "ms",
    direction = "lower",
  })
  work.append_result(path, {metric = 100, metrics = {}, status = "keep", description = "baseline"})
  work.append_result(path, {metric = 90, metrics = {}, status = "keep", description = "faster"})
  work.append_result(path, {metric = 110, metrics = {}, status = "discard", description = "slower"})

  local state = work.load_state(path)
  local summary = work.format_summary(state)
  assert(summary:find("3"), "should mention 3 experiments: " .. summary)
  assert(summary:find("2 kept"), "should mention 2 kept: " .. summary)
  assert(summary:find("1 discarded"), "should mention 1 discarded: " .. summary)
  assert(summary:find("90"), "should mention best metric 90: " .. summary)
  assert(summary:find("baseline") or summary:find("100"), "should mention baseline: " .. summary)
  print("✓ format_summary")
end
test_format_summary()

print("\nall work tests passed")
