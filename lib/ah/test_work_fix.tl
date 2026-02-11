#!/usr/bin/env cosmic
-- test_work_fix.tl: tests for check-to-do retry loop helpers
--
-- The work flow is linear: plan -> do -> push -> check -> act.
-- When check returns "needs-fixes", the work is wasted — no PR, issue
-- labeled failed. These tests cover helpers for a retry loop:
-- check feedback is fed back into a fix prompt, do/push/check re-run.

local record ParsedActions
  verdict: string
  actions: {any}
  success: boolean
end

local record AgentLimits
  max_tokens: integer
  timeout_sec: integer
end

local record Work
  build_fix_prompt: function(string, string, string, string, string): string
  build_friction_prompt: function(string, string): string
  build_agent_args: function(string, string, string, boolean, AgentLimits, string): {string}
  parse_actions: function(string): ParsedActions, string
  interpolate_prompt: function(string, {string:string}): string
end

local work = require("ah.work") as Work

-- Test: build_fix_prompt interpolates all variables
local function test_build_fix_prompt_basic()
  local template = "Title: {title}\nPlan:\n{plan.md contents}\nFeedback:\n{check.md contents}\nBranch: {branch}"
  local result = work.build_fix_prompt(template, "fix docs", "the plan", "model name is wrong", "work/79")
  assert(result == "Title: fix docs\nPlan:\nthe plan\nFeedback:\nmodel name is wrong\nBranch: work/79",
    "should interpolate all vars, got: " .. tostring(result))
  print("ok build_fix_prompt interpolates all variables")
end
test_build_fix_prompt_basic()

-- Test: build_fix_prompt handles % in check feedback
local function test_build_fix_prompt_percent()
  local template = "Plan:\n{plan.md contents}\nFeedback:\n{check.md contents}"
  local check = "coverage dropped from 100% to 50%"
  local ok, result = pcall(work.build_fix_prompt, template, "t", "p", check, "work/1")
  assert(ok, "should not crash with % in check feedback, got: " .. tostring(result))
  print("ok build_fix_prompt handles % in check feedback")
end
test_build_fix_prompt_percent()

-- Test: parse_actions returns needs-fixes verdict correctly
local function test_parse_needs_fixes()
  local content = '{"verdict": "needs-fixes", "actions": [{"action": "comment_issue", "body": "fix the model name"}]}'
  local result = work.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "needs-fixes", "verdict should be needs-fixes, got: " .. result.verdict)
  assert(result.success == false, "success should be false for needs-fixes")
  assert(#result.actions == 1, "should have one action")
  print("ok parse_actions handles needs-fixes verdict")
end
test_parse_needs_fixes()

-- Test: build_friction_prompt interpolates friction_path
local function test_build_friction_prompt_basic()
  local template = "reflect on friction.\n\nWrite `{friction_path}`:\n\n    ## Friction\n    <items>"
  local result = work.build_friction_prompt(template, "o/work/plan/friction.md")
  assert(result == "reflect on friction.\n\nWrite `o/work/plan/friction.md`:\n\n    ## Friction\n    <items>",
    "should interpolate friction_path, got: " .. tostring(result))
  print("ok build_friction_prompt interpolates friction_path")
end
test_build_friction_prompt_basic()

-- Test: build_friction_prompt handles different phase paths
local function test_build_friction_prompt_phases()
  local template = "Write `{friction_path}`"
  for _, path in ipairs({"o/work/plan/friction.md", "o/work/do/friction.md", "o/work/check/friction.md"}) do
    local result = work.build_friction_prompt(template, path)
    assert(result == "Write `" .. path .. "`",
      "should interpolate " .. path .. ", got: " .. tostring(result))
  end
  print("ok build_friction_prompt works for all phase paths")
end
test_build_friction_prompt_phases()

-- Test: fix.md prompt writes artifacts to o/work/fix/, not o/work/do/
local function test_fix_prompt_uses_fix_directory()
  local f = io.open("sys/work/fix.md", "r")
  assert(f, "should be able to read sys/work/fix.md")
  local content = f:read("*a")
  f:close()
  -- fix prompt must write to o/work/fix/ so it doesn't overwrite do phase artifacts
  assert(content:find("o/work/fix/do.md", 1, true),
    "fix prompt should write to o/work/fix/do.md")
  assert(content:find("o/work/fix/update.md", 1, true),
    "fix prompt should write to o/work/fix/update.md")
  -- must not reference o/work/do/ for output paths
  assert(not content:find("o/work/do/do.md", 1, true),
    "fix prompt must not write to o/work/do/do.md (would overwrite do phase artifacts)")
  assert(not content:find("o/work/do/update.md", 1, true),
    "fix prompt must not write to o/work/do/update.md (would overwrite do phase artifacts)")
  print("ok fix.md prompt writes to o/work/fix/ directory")
end
test_fix_prompt_uses_fix_directory()

-- Test: build_friction_prompt works for fix phase path
local function test_build_friction_prompt_fix_phase()
  local template = "Write `{friction_path}`"
  local result = work.build_friction_prompt(template, "o/work/fix/friction.md")
  assert(result == "Write `o/work/fix/friction.md`",
    "should interpolate o/work/fix/friction.md, got: " .. tostring(result))
  print("ok build_friction_prompt works for fix phase path")
end
test_build_friction_prompt_fix_phase()

-- Test: build_agent_args with new session, no limits
local function test_agent_args_basic()
  local args = work.build_agent_args("ah", "test.db", "hello", true, nil, nil)
  assert(args[1] == "ah", "exe should be ah, got: " .. args[1])
  assert(args[2] == "-n", "should have -n for new session, got: " .. args[2])
  assert(args[3] == "--db", "should have --db, got: " .. args[3])
  assert(args[4] == "test.db", "should have db path, got: " .. args[4])
  assert(args[5] == "hello", "should have prompt, got: " .. args[5])
  assert(#args == 5, "should have 5 args, got: " .. #args)
  print("ok build_agent_args basic new session")
end
test_agent_args_basic()

-- Test: build_agent_args continue session (no -n)
local function test_agent_args_continue()
  local args = work.build_agent_args("ah", "test.db", "hello", false, nil, nil)
  assert(args[1] == "ah", "exe should be ah")
  assert(args[2] == "--db", "should have --db without -n, got: " .. args[2])
  assert(args[3] == "test.db")
  assert(args[4] == "hello")
  assert(#args == 4, "should have 4 args, got: " .. #args)
  print("ok build_agent_args continue session")
end
test_agent_args_continue()

-- Test: build_agent_args with max_tokens
local function test_agent_args_max_tokens()
  local limits: AgentLimits = {max_tokens = 50000, timeout_sec = 0}
  local args = work.build_agent_args("ah", "test.db", "hello", true, limits, nil)
  -- Should be: ah -n --max-tokens 50000 --db test.db hello
  local joined = table.concat(args, " ")
  assert(joined:find("--max%-tokens 50000"), "should have --max-tokens 50000, got: " .. joined)
  assert(args[1] == "ah")
  assert(args[#args] == "hello", "prompt should be last arg, got: " .. args[#args])
  print("ok build_agent_args with max_tokens")
end
test_agent_args_max_tokens()

-- Test: build_agent_args with timeout wraps in timeout command
local function test_agent_args_timeout()
  local limits: AgentLimits = {max_tokens = 0, timeout_sec = 300}
  local args = work.build_agent_args("ah", "test.db", "hello", true, limits, nil)
  -- Should be: timeout 300 ah -n --db test.db hello
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "300", "should have timeout seconds, got: " .. args[2])
  assert(args[3] == "ah", "exe should follow timeout, got: " .. args[3])
  assert(args[#args] == "hello", "prompt should be last, got: " .. args[#args])
  print("ok build_agent_args with timeout")
end
test_agent_args_timeout()

-- Test: build_agent_args with both limits
local function test_agent_args_both_limits()
  local limits: AgentLimits = {max_tokens = 100000, timeout_sec = 300}
  local args = work.build_agent_args("ah", "test.db", "hello", true, limits, nil)
  local joined = table.concat(args, " ")
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "300", "timeout value, got: " .. args[2])
  assert(joined:find("--max%-tokens 100000"), "should have --max-tokens, got: " .. joined)
  assert(args[#args] == "hello", "prompt last, got: " .. args[#args])
  print("ok build_agent_args with both limits")
end
test_agent_args_both_limits()

-- Test: build_agent_args with model
local function test_agent_args_model()
  local args = work.build_agent_args("ah", "test.db", "hello", true, nil, "opus")
  local joined = table.concat(args, " ")
  assert(joined:find("-m opus"), "should have -m opus, got: " .. joined)
  assert(args[1] == "ah")
  assert(args[#args] == "hello", "prompt should be last arg, got: " .. args[#args])
  print("ok build_agent_args with model")
end
test_agent_args_model()

-- Test: build_agent_args with model and limits
local function test_agent_args_model_and_limits()
  local limits: AgentLimits = {max_tokens = 50000, timeout_sec = 180}
  local args = work.build_agent_args("ah", "test.db", "hello", true, limits, "haiku")
  local joined = table.concat(args, " ")
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "180", "timeout value, got: " .. args[2])
  assert(joined:find("-m haiku"), "should have -m haiku, got: " .. joined)
  assert(joined:find("--max%-tokens 50000"), "should have --max-tokens, got: " .. joined)
  assert(args[#args] == "hello", "prompt last, got: " .. args[#args])
  print("ok build_agent_args with model and limits")
end
test_agent_args_model_and_limits()

-- Test: build_agent_args without model (nil) doesn't add -m
local function test_agent_args_no_model()
  local args = work.build_agent_args("ah", "test.db", "hello", true, nil, nil)
  local joined = table.concat(args, " ")
  assert(not joined:find("-m "), "should not have -m when model is nil, got: " .. joined)
  print("ok build_agent_args without model omits -m")
end
test_agent_args_no_model()

print("\nAll work-fix tests passed!")
