#!/usr/bin/env cosmic
local db = require("ah.db")
local work = require("ah.work")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")

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

-- test: init_work_db and format_history
local function test_work_db()
  local db_path = fs.join(TEST_TMPDIR, "test_work.db")
  fs.unlink(db_path)
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
  fs.unlink(db_path)
  print("PASS test_work_db")
end
test_work_db()

-- test: work_opts_defaults
local function test_work_opts_defaults()
  -- nil opts → all defaults
  local t, m, mt = work.work_opts_defaults(nil)
  assert(t == 300, "default timeout should be 300, got " .. tostring(t))
  assert(m == 16384, "default max_tokens should be 16384, got " .. tostring(m))
  assert(mt == nil, "default max_turn_tokens should be nil")

  -- empty opts → all defaults
  t, m, mt = work.work_opts_defaults({timeout = nil, max_tokens = nil, max_turn_tokens = nil})
  assert(t == 300, "empty opts: default timeout")
  assert(m == 16384, "empty opts: default max_tokens")
  assert(mt == nil, "empty opts: default max_turn_tokens nil")

  -- explicit opts override defaults
  t, m, mt = work.work_opts_defaults({timeout = 60, max_tokens = 8192, max_turn_tokens = 4096})
  assert(t == 60, "explicit timeout")
  assert(m == 8192, "explicit max_tokens")
  assert(mt == 4096, "explicit max_turn_tokens")

  -- partial opts: only timeout set
  t, m, mt = work.work_opts_defaults({timeout = 120})
  assert(t == 120, "partial: timeout set")
  assert(m == 16384, "partial: max_tokens default")
  assert(mt == nil, "partial: max_turn_tokens nil")

  print("PASS test_work_opts_defaults")
end
test_work_opts_defaults()
