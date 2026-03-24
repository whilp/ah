#!/usr/bin/env cosmic
local db = require("ah.db")
local work = require("ah.work")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")
local ulid = require("ulid")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"

-- test: parse_metric
local function test_parse_metric()
  assert(work.parse_metric("42.3\n") == 42.3, "basic")
  assert(work.parse_metric("  99.5  \n") == 99.5, "whitespace")
  assert(work.parse_metric("1234567\n") == 1234567, "integer")
  assert(work.parse_metric("") == nil, "empty")
  assert(work.parse_metric("\n") == nil, "newline")
  assert(work.parse_metric("hello\n") == nil, "text")
  assert(work.parse_metric("42.3\nextra\n") == nil, "multiline")
  print("PASS test_parse_metric")
end
test_parse_metric()

-- test: fmt_pct
local function test_fmt_pct()
  assert(work.fmt_pct(90, 100) == "-10.0%", "decrease")
  assert(work.fmt_pct(110, 100) == "+10.0%", "increase")
  assert(work.fmt_pct(100, 0) == "", "zero baseline")
  print("PASS test_fmt_pct")
end
test_fmt_pct()

-- test: format_history uses work_iterations from main schema
local function test_work_db()
  local db_path = fs.join(TEST_TMPDIR, "test_work.db")
  fs.unlink(db_path)
  local d = db.open(db_path)

  local h = work.format_history(d, 10)
  assert(h == "no previous iterations.", "empty history")

  -- Insert baseline + iteration rows with ULIDs
  d._db:exec([[
    insert into work_iterations (id, status, metric_value, baseline_value, message, created_at)
    values (?, 'baseline', 42.3, 42.3, 'initial baseline', 999)
  ]], ulid.generate())
  d._db:exec([[
    insert into work_iterations (id, status, metric_value, baseline_value, message, created_at)
    values (?, 'keep', 38.1, 42.3, 'inlined hot path', 1000)
  ]], ulid.generate())
  d._db:exec([[
    insert into work_iterations (id, status, metric_value, baseline_value, message, created_at)
    values (?, 'discard', 39.5, 38.1, 'removed bounds check', 1001)
  ]], ulid.generate())

  h = work.format_history(d, 10)
  assert(h:match("keep"), "should contain keep")
  assert(h:match("discard"), "should contain discard")
  assert(h:match("38.1"), "should contain metric")

  db.close(d)
  fs.unlink(db_path)
  print("PASS test_work_db")
end
test_work_db()

-- test: get_best and get_baseline derive from rows
local function test_best_baseline()
  local db_path = fs.join(TEST_TMPDIR, "test_work_best.db")
  fs.unlink(db_path)
  local d = db.open(db_path)

  -- No rows yet
  assert(work.get_best(d) == nil, "no best yet")
  assert(work.get_baseline(d) == nil, "no baseline yet")

  -- Add baseline row
  d._db:exec([[
    insert into work_iterations (id, status, metric_value, baseline_value, message, created_at)
    values (?, 'baseline', 42.3, 42.3, 'initial baseline', 1000)
  ]], ulid.generate())

  assert(work.get_best(d) == 42.3, "best is baseline")
  assert(work.get_baseline(d) == 42.3, "baseline")

  -- Add a keep row with improvement
  d._db:exec([[
    insert into work_iterations (id, status, metric_value, baseline_value, message, created_at)
    values (?, 'keep', 38.1, 42.3, 'improvement', 1001)
  ]], ulid.generate())

  assert(work.get_best(d) == 38.1, "best updated after keep")
  assert(work.get_baseline(d) == 42.3, "baseline unchanged")

  -- Add a discard row — should not affect best
  d._db:exec([[
    insert into work_iterations (id, status, metric_value, baseline_value, message, created_at)
    values (?, 'discard', 50.0, 38.1, 'regression', 1002)
  ]], ulid.generate())

  assert(work.get_best(d) == 38.1, "best unchanged after discard")

  db.close(d)
  fs.unlink(db_path)
  print("PASS test_best_baseline")
end
test_best_baseline()
