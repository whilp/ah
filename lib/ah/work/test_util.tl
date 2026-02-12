#!/usr/bin/env cosmic
-- test_util.tl: tests for ah.work.util module

local record WorkUtil
  slice: function({string}, integer): {string}
  env_get: function({string}, string): string
  env_set: function({string}, string, string)
  setup_git_env: function({string})
  extract_branch: function(string, string): string
  format_protect_dirs: function({string}): string
  format_run_error: function(string, string, string): string
end

local util = require("ah.work.util") as WorkUtil

-- Test slice helper
local function test_slice()
  local t = {"a", "b", "c", "d"}
  local s = util.slice(t, 2)
  assert(#s == 3, "slice from 2 should have 3 elements, got: " .. #s)
  assert(s[1] == "b", "first element should be b")
  assert(s[2] == "c", "second element should be c")
  assert(s[3] == "d", "third element should be d")
  print("✓ slice works correctly")
end
test_slice()

-- Test slice with start beyond length
local function test_slice_empty()
  local t = {"a", "b"}
  local s = util.slice(t, 5)
  assert(#s == 0, "slice beyond length should be empty")
  print("✓ slice returns empty for out-of-range start")
end
test_slice_empty()

-- Test env_get finds values
local function test_env_get()
  local e: {string} = {"FOO=bar", "BAZ=qux"}
  assert(util.env_get(e, "FOO") == "bar", "should find FOO")
  assert(util.env_get(e, "BAZ") == "qux", "should find BAZ")
  assert(util.env_get(e, "MISSING") == nil, "should return nil for missing")
  print("✓ env_get works correctly")
end
test_env_get()

-- Test env_set appends values
local function test_env_set()
  local e: {string} = {}
  util.env_set(e, "KEY", "value")
  assert(#e == 1, "should have 1 entry")
  assert(e[1] == "KEY=value", "should format as KEY=value")
  print("✓ env_set works correctly")
end
test_env_set()

-- Test setup_git_env sets defaults when no GITHUB_ACTOR
local function test_setup_git_env_defaults()
  local e: {string} = {}
  util.setup_git_env(e)
  assert(util.env_get(e, "GIT_AUTHOR_NAME") == "ah-agent", "should default author name, got: " .. tostring(util.env_get(e, "GIT_AUTHOR_NAME")))
  assert(util.env_get(e, "GIT_AUTHOR_EMAIL") == "ah-agent@localhost", "should default author email, got: " .. tostring(util.env_get(e, "GIT_AUTHOR_EMAIL")))
  assert(util.env_get(e, "GIT_COMMITTER_NAME") == "ah-agent", "should default committer name, got: " .. tostring(util.env_get(e, "GIT_COMMITTER_NAME")))
  assert(util.env_get(e, "GIT_COMMITTER_EMAIL") == "ah-agent@localhost", "should default committer email, got: " .. tostring(util.env_get(e, "GIT_COMMITTER_EMAIL")))
  print("✓ setup_git_env sets defaults")
end
test_setup_git_env_defaults()

-- Test setup_git_env uses GITHUB_ACTOR when available
local function test_setup_git_env_github_actor()
  local e: {string} = {"GITHUB_ACTOR=octocat"}
  util.setup_git_env(e)
  assert(util.env_get(e, "GIT_AUTHOR_NAME") == "octocat", "should use GITHUB_ACTOR for name, got: " .. tostring(util.env_get(e, "GIT_AUTHOR_NAME")))
  assert(util.env_get(e, "GIT_AUTHOR_EMAIL") == "octocat@users.noreply.github.com", "should derive email, got: " .. tostring(util.env_get(e, "GIT_AUTHOR_EMAIL")))
  assert(util.env_get(e, "GIT_COMMITTER_NAME") == "octocat", "should use GITHUB_ACTOR for committer, got: " .. tostring(util.env_get(e, "GIT_COMMITTER_NAME")))
  assert(util.env_get(e, "GIT_COMMITTER_EMAIL") == "octocat@users.noreply.github.com", "should derive committer email, got: " .. tostring(util.env_get(e, "GIT_COMMITTER_EMAIL")))
  print("✓ setup_git_env uses GITHUB_ACTOR")
end
test_setup_git_env_github_actor()

-- Test setup_git_env does not overwrite already-set values
local function test_setup_git_env_no_overwrite()
  local e: {string} = {
    "GIT_AUTHOR_NAME=custom",
    "GIT_AUTHOR_EMAIL=custom@example.com",
    "GIT_COMMITTER_NAME=custom",
    "GIT_COMMITTER_EMAIL=custom@example.com",
  }
  util.setup_git_env(e)
  assert(util.env_get(e, "GIT_AUTHOR_NAME") == "custom", "should not overwrite existing name")
  assert(util.env_get(e, "GIT_AUTHOR_EMAIL") == "custom@example.com", "should not overwrite existing email")
  print("✓ setup_git_env preserves existing values")
end
test_setup_git_env_no_overwrite()

-- Test extract_branch with explicit branch in plan
local function test_extract_branch_explicit()
  local plan = [[
# Plan

Branch: feature/custom-branch

## Tasks
- Do something
]]
  local branch = util.extract_branch(plan, "123")
  assert(branch == "feature/custom-branch", "should extract explicit branch, got: " .. branch)
  print("✓ extract_branch extracts explicit branch from plan")
end
test_extract_branch_explicit()

-- Test extract_branch falls back to default
local function test_extract_branch_default()
  local plan = [[
# Plan

## Tasks
- Do something
]]
  local branch = util.extract_branch(plan, "456")
  assert(branch == "work/456", "should use default branch, got: " .. branch)
  print("✓ extract_branch falls back to work/<number>")
end
test_extract_branch_default()

-- Test extract_branch with branch at different position
local function test_extract_branch_middle()
  local plan = [[
# Plan

Some intro text.

Branch: work/issue-789

More text here.
]]
  local branch = util.extract_branch(plan, "000")
  assert(branch == "work/issue-789", "should find branch in middle, got: " .. branch)
  print("✓ extract_branch finds branch anywhere in plan")
end
test_extract_branch_middle()

-- Test: format_protect_dirs joins paths with colons
local function test_format_protect_dirs_single()
  local result = util.format_protect_dirs({"o/work/plan"})
  assert(result == "o/work/plan",
    "single dir should format as-is, got: " .. tostring(result))
  print("✓ format_protect_dirs handles single directory")
end
test_format_protect_dirs_single()

local function test_format_protect_dirs_multiple()
  local result = util.format_protect_dirs({"o/work/plan", "o/work/do"})
  assert(result == "o/work/plan:o/work/do",
    "multiple dirs should be colon-separated, got: " .. tostring(result))
  print("✓ format_protect_dirs handles multiple directories")
end
test_format_protect_dirs_multiple()

local function test_format_protect_dirs_empty()
  local result = util.format_protect_dirs({})
  assert(result == nil, "empty list should return nil, got: " .. tostring(result))
  print("✓ format_protect_dirs returns nil for empty list")
end
test_format_protect_dirs_empty()

local function test_format_protect_dirs_nil()
  local result = util.format_protect_dirs(nil)
  assert(result == nil, "nil should return nil, got: " .. tostring(result))
  print("✓ format_protect_dirs returns nil for nil input")
end
test_format_protect_dirs_nil()

-- Test format_run_error prefers stderr
local function test_format_error_prefers_stderr()
  local msg = util.format_run_error("gh pr create failed", nil, "GraphQL: not permitted")
  assert(msg == "gh pr create failed: GraphQL: not permitted",
    "should prefer stderr when stdout is nil, got: " .. msg)
  print("✓ format_run_error prefers stderr over nil stdout")
end
test_format_error_prefers_stderr()

local function test_format_error_prefers_stderr_over_empty()
  local msg = util.format_run_error("gh pr create failed", "", "permission denied")
  assert(msg == "gh pr create failed: permission denied",
    "should prefer stderr over empty stdout, got: " .. msg)
  print("✓ format_run_error prefers stderr over empty stdout")
end
test_format_error_prefers_stderr_over_empty()

local function test_format_error_falls_back_to_stdout()
  local msg = util.format_run_error("command failed", "some stdout error", nil)
  assert(msg == "command failed: some stdout error",
    "should use stdout when no stderr, got: " .. msg)
  print("✓ format_run_error falls back to stdout when no stderr")
end
test_format_error_falls_back_to_stdout()

local function test_format_error_both_nil()
  local msg = util.format_run_error("command failed", nil, nil)
  assert(msg == "command failed: no output",
    "should say 'no output' when both nil, got: " .. msg)
  print("✓ format_run_error handles both nil")
end
test_format_error_both_nil()

print("\nAll work-util tests passed!")
