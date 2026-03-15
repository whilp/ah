#!/usr/bin/env cosmic
local db = require("ah.db")
local work = require("ah.work")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")
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

-- helper: run a shell command in a directory, return stdout
local function sh(dir: string, cmd: string): string
  local handle = child.spawn({"sh", "-c", "cd " .. dir .. " && " .. cmd})
  if not handle then return "" end
  handle.stderr:read()
  local ok, out = handle:read()
  if not ok then return "" end
  local s = ((out as string) or ""):gsub("%s+$", "")
  return s
end

-- test: commit_work_doc + git_revert preserves work doc, reverts code
local function test_work_doc_survives_revert()
  local repo = fs.join(TEST_TMPDIR, "test_revert_md")
  -- clean up any prior run
  sh(TEST_TMPDIR, "rm -rf " .. repo)
  fs.mkdir(repo)

  -- init a git repo with initial files
  sh(repo, "git init")
  sh(repo, "git config user.email test@test.com")
  sh(repo, "git config user.name test")
  cio.barf(fs.join(repo, "code.tl"), "original code")
  cio.barf(fs.join(repo, "work.md"), "# ideas\n- idea 1\n")
  cio.barf(fs.join(repo, "docs.md"), "original docs")
  sh(repo, "git add -A && git commit -m init")

  -- simulate an agent iteration: modify code, work doc, another .md,
  -- and write the result file
  cio.barf(fs.join(repo, "code.tl"), "modified code")
  cio.barf(fs.join(repo, "work.md"), "# ideas\n- idea 1 ✗ discarded\n- idea 2 (new)\n")
  cio.barf(fs.join(repo, "docs.md"), "modified docs")
  fs.mkdir(fs.join(repo, ".ah"))
  cio.barf(fs.join(repo, ".ah", "work-result.json"), '{"work_doc": "work.md"}')

  local prev_cwd = fs.getcwd()
  fs.chdir(repo)

  -- read result and commit work doc (as run_work would)
  local doc = work.read_work_result()
  assert(doc == "work.md", "should read work_doc from result json, got: " .. (doc or "nil"))
  work.commit_work_doc(doc)

  -- revert remaining changes
  work.git_revert()
  fs.chdir(prev_cwd)

  -- code.tl should be reverted
  local code = cio.slurp(fs.join(repo, "code.tl"))
  assert(code == "original code", "code.tl should be reverted, got: " .. (code or "nil"))

  -- docs.md should be reverted
  local docs = cio.slurp(fs.join(repo, "docs.md"))
  assert(docs == "original docs", "docs.md should be reverted, got: " .. (docs or "nil"))

  -- work.md should be preserved (committed separately)
  local md = cio.slurp(fs.join(repo, "work.md"))
  assert(md and md:match("idea 2"), "work.md should preserve updates, got: " .. (md or "nil"))
  assert(md and md:match("discarded"), "work.md should preserve annotations, got: " .. (md or "nil"))

  -- clean up
  sh(TEST_TMPDIR, "rm -rf " .. repo)
  print("PASS test_work_doc_survives_revert")
end
test_work_doc_survives_revert()
