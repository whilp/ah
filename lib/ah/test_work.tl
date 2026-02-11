#!/usr/bin/env cosmic
-- test_work.tl: tests for unified work module

local record Work
  main: function({string}): integer
  slice: function({string}, integer): {string}
  setup_git_env: function({string:string})
end

local work = require("ah.work") as Work

-- Test slice helper
local function test_slice()
  local t = {"a", "b", "c", "d"}
  local s = work.slice(t, 2)
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
  local s = work.slice(t, 5)
  assert(#s == 0, "slice beyond length should be empty")
  print("✓ slice returns empty for out-of-range start")
end
test_slice_empty()

-- Test that help returns 0
local function test_help()
  local rc = work.main({"-h"})
  assert(rc == 0, "help should return 0")
  print("✓ -h returns 0")
end
test_help()

-- Test that --help returns 0
local function test_long_help()
  local rc = work.main({"--help"})
  assert(rc == 0, "--help should return 0")
  print("✓ --help returns 0")
end
test_long_help()

-- Test that no args (no repo) returns 1
local function test_no_args()
  local rc = work.main({"--no-sandbox"})
  assert(rc == 1, "no args should return 1, got: " .. tostring(rc))
  print("✓ no args returns 1 (missing repo)")
end
test_no_args()

-- Test subcommand plan --help returns 0
local function test_plan_help()
  local rc = work.main({"--no-sandbox", "plan", "--help"})
  assert(rc == 0, "plan --help should return 0")
  print("✓ plan --help returns 0")
end
test_plan_help()

-- Test subcommand plan without required args returns 1
local function test_plan_no_args()
  local rc = work.main({"--no-sandbox", "plan"})
  assert(rc == 1, "plan without --repo should return 1, got: " .. tostring(rc))
  print("✓ plan without --repo returns 1")
end
test_plan_no_args()

-- Test subcommand do --help returns 0
local function test_do_help()
  local rc = work.main({"--no-sandbox", "do", "--help"})
  assert(rc == 0, "do --help should return 0")
  print("✓ do --help returns 0")
end
test_do_help()

-- Test subcommand do without required args returns 1
local function test_do_no_args()
  local rc = work.main({"--no-sandbox", "do"})
  assert(rc == 1, "do without --title/--number should return 1, got: " .. tostring(rc))
  print("✓ do without --title/--number returns 1")
end
test_do_no_args()

-- Test subcommand act --help returns 0
local function test_act_help()
  local rc = work.main({"--no-sandbox", "act", "--help"})
  assert(rc == 0, "act --help should return 0")
  print("✓ act --help returns 0")
end
test_act_help()

-- Test subcommand act without required args returns 1
local function test_act_no_args()
  local rc = work.main({"--no-sandbox", "act"})
  assert(rc == 1, "act without --issue-url should return 1, got: " .. tostring(rc))
  print("✓ act without --issue-url returns 1")
end
test_act_no_args()

-- Test setup_git_env sets defaults when no GITHUB_ACTOR
local function test_setup_git_env_defaults()
  local e: {string:string} = {}
  work.setup_git_env(e)
  assert(e.GIT_AUTHOR_NAME == "ah-agent", "should default author name, got: " .. tostring(e.GIT_AUTHOR_NAME))
  assert(e.GIT_AUTHOR_EMAIL == "ah-agent@localhost", "should default author email, got: " .. tostring(e.GIT_AUTHOR_EMAIL))
  assert(e.GIT_COMMITTER_NAME == "ah-agent", "should default committer name, got: " .. tostring(e.GIT_COMMITTER_NAME))
  assert(e.GIT_COMMITTER_EMAIL == "ah-agent@localhost", "should default committer email, got: " .. tostring(e.GIT_COMMITTER_EMAIL))
  print("✓ setup_git_env sets defaults")
end
test_setup_git_env_defaults()

-- Test setup_git_env uses GITHUB_ACTOR when available
local function test_setup_git_env_github_actor()
  local e: {string:string} = {GITHUB_ACTOR = "octocat"}
  work.setup_git_env(e)
  assert(e.GIT_AUTHOR_NAME == "octocat", "should use GITHUB_ACTOR for name, got: " .. tostring(e.GIT_AUTHOR_NAME))
  assert(e.GIT_AUTHOR_EMAIL == "octocat@users.noreply.github.com", "should derive email, got: " .. tostring(e.GIT_AUTHOR_EMAIL))
  assert(e.GIT_COMMITTER_NAME == "octocat", "should use GITHUB_ACTOR for committer, got: " .. tostring(e.GIT_COMMITTER_NAME))
  assert(e.GIT_COMMITTER_EMAIL == "octocat@users.noreply.github.com", "should derive committer email, got: " .. tostring(e.GIT_COMMITTER_EMAIL))
  print("✓ setup_git_env uses GITHUB_ACTOR")
end
test_setup_git_env_github_actor()

-- Test setup_git_env does not overwrite already-set values
local function test_setup_git_env_no_overwrite()
  local e: {string:string} = {
    GIT_AUTHOR_NAME = "custom",
    GIT_AUTHOR_EMAIL = "custom@example.com",
    GIT_COMMITTER_NAME = "custom",
    GIT_COMMITTER_EMAIL = "custom@example.com",
  }
  work.setup_git_env(e)
  assert(e.GIT_AUTHOR_NAME == "custom", "should not overwrite existing name")
  assert(e.GIT_AUTHOR_EMAIL == "custom@example.com", "should not overwrite existing email")
  print("✓ setup_git_env preserves existing values")
end
test_setup_git_env_no_overwrite()

print("\nAll work tests passed!")
