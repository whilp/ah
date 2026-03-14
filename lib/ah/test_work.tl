#!/usr/bin/env cosmic
local db = require("ah.db")
local work = require("ah.work")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

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

-- test: init_work_db and format_history
local function test_work_db()
  local db_path = fs.join(TEST_TMPDIR, "test_work.db")
  os.remove(db_path)
  local d = db.open(db_path)
  work.init_work_db(d)
  work.init_work_db(d) -- idempotent

  local h = work.format_history(d, 10)
  assert(h == "no previous iterations.", "empty history")

  -- Insert via raw sql since record_iteration uses os.time()
  d._db:exec([[
    insert into work_iterations (status, metric_value, baseline_value, message, created_at)
    values ('keep', 38.1, 42.3, 'inlined hot path', 1000)
  ]])
  d._db:exec([[
    insert into work_iterations (status, metric_value, baseline_value, message, created_at)
    values ('discard', 39.5, 38.1, 'removed bounds check', 1001)
  ]])

  h = work.format_history(d, 10)
  assert(h:match("keep"), "should contain keep")
  assert(h:match("discard"), "should contain discard")
  assert(h:match("38.1"), "should contain metric")

  db.close(d)
  os.remove(db_path)
  print("PASS test_work_db")
end
test_work_db()

-- test: parse_verdict
local function test_parse_verdict()
  local decision: string
  local msg: string

  decision, msg = work.parse_verdict("KEEP: improved hot path")
  assert(decision == "keep", "keep decision")
  assert(msg == "improved hot path", "keep msg")

  decision, msg = work.parse_verdict("DISCARD: no real improvement")
  assert(decision == "discard", "discard decision")
  assert(msg == "no real improvement", "discard msg")

  -- agent may prefix with text
  decision, msg = work.parse_verdict("Looking at the diff...\nKEEP: good change")
  assert(decision == "keep", "keep with prefix")
  assert(msg == "good change", "keep msg with prefix")

  decision, msg = work.parse_verdict("no verdict here")
  assert(decision == "discard", "fallback to discard")

  print("PASS test_parse_verdict")
end
test_parse_verdict()
