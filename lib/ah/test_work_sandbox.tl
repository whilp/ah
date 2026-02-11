#!/usr/bin/env cosmic
-- test_work_sandbox.tl: tests for work_sandbox module

local record AgentLimits
  max_tokens: integer
  timeout_sec: integer
end

local record WorkSandbox
  build_agent_args: function(string, string, string, boolean, AgentLimits, string): {string}
end

local sandbox = require("ah.work_sandbox") as WorkSandbox

-- Test: build_agent_args with new session, no limits
local function test_agent_args_basic()
  local args = sandbox.build_agent_args("ah", "test.db", "hello", true, nil, nil)
  assert(args[1] == "ah", "exe should be ah, got: " .. args[1])
  assert(args[2] == "-n", "should have -n for new session, got: " .. args[2])
  assert(args[3] == "--db", "should have --db, got: " .. args[3])
  assert(args[4] == "test.db", "should have db path, got: " .. args[4])
  assert(args[5] == "hello", "should have prompt, got: " .. args[5])
  assert(#args == 5, "should have 5 args, got: " .. #args)
  print("✓ build_agent_args basic new session")
end
test_agent_args_basic()

-- Test: build_agent_args continue session (no -n)
local function test_agent_args_continue()
  local args = sandbox.build_agent_args("ah", "test.db", "hello", false, nil, nil)
  assert(args[1] == "ah", "exe should be ah")
  assert(args[2] == "--db", "should have --db without -n, got: " .. args[2])
  assert(args[3] == "test.db")
  assert(args[4] == "hello")
  assert(#args == 4, "should have 4 args, got: " .. #args)
  print("✓ build_agent_args continue session")
end
test_agent_args_continue()

-- Test: build_agent_args with max_tokens
local function test_agent_args_max_tokens()
  local limits: AgentLimits = {max_tokens = 50000, timeout_sec = 0}
  local args = sandbox.build_agent_args("ah", "test.db", "hello", true, limits, nil)
  -- Should be: ah -n --max-tokens 50000 --db test.db hello
  local joined = table.concat(args, " ")
  assert(joined:find("--max%-tokens 50000"), "should have --max-tokens 50000, got: " .. joined)
  assert(args[1] == "ah")
  assert(args[#args] == "hello", "prompt should be last arg, got: " .. args[#args])
  print("✓ build_agent_args with max_tokens")
end
test_agent_args_max_tokens()

-- Test: build_agent_args with timeout wraps in timeout command
local function test_agent_args_timeout()
  local limits: AgentLimits = {max_tokens = 0, timeout_sec = 300}
  local args = sandbox.build_agent_args("ah", "test.db", "hello", true, limits, nil)
  -- Should be: timeout 300 ah -n --db test.db hello
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "300", "should have timeout seconds, got: " .. args[2])
  assert(args[3] == "ah", "exe should follow timeout, got: " .. args[3])
  assert(args[#args] == "hello", "prompt should be last, got: " .. args[#args])
  print("✓ build_agent_args with timeout")
end
test_agent_args_timeout()

-- Test: build_agent_args with both limits
local function test_agent_args_both_limits()
  local limits: AgentLimits = {max_tokens = 100000, timeout_sec = 300}
  local args = sandbox.build_agent_args("ah", "test.db", "hello", true, limits, nil)
  local joined = table.concat(args, " ")
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "300", "timeout value, got: " .. args[2])
  assert(joined:find("--max%-tokens 100000"), "should have --max-tokens, got: " .. joined)
  assert(args[#args] == "hello", "prompt last, got: " .. args[#args])
  print("✓ build_agent_args with both limits")
end
test_agent_args_both_limits()

-- Test: build_agent_args with model
local function test_agent_args_model()
  local args = sandbox.build_agent_args("ah", "test.db", "hello", true, nil, "opus")
  local joined = table.concat(args, " ")
  assert(joined:find("-m opus"), "should have -m opus, got: " .. joined)
  assert(args[1] == "ah")
  assert(args[#args] == "hello", "prompt should be last arg, got: " .. args[#args])
  print("✓ build_agent_args with model")
end
test_agent_args_model()

-- Test: build_agent_args with model and limits
local function test_agent_args_model_and_limits()
  local limits: AgentLimits = {max_tokens = 50000, timeout_sec = 180}
  local args = sandbox.build_agent_args("ah", "test.db", "hello", true, limits, "haiku")
  local joined = table.concat(args, " ")
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "180", "timeout value, got: " .. args[2])
  assert(joined:find("-m haiku"), "should have -m haiku, got: " .. joined)
  assert(joined:find("--max%-tokens 50000"), "should have --max-tokens, got: " .. joined)
  assert(args[#args] == "hello", "prompt last, got: " .. args[#args])
  print("✓ build_agent_args with model and limits")
end
test_agent_args_model_and_limits()

-- Test: build_agent_args without model (nil) doesn't add -m
local function test_agent_args_no_model()
  local args = sandbox.build_agent_args("ah", "test.db", "hello", true, nil, nil)
  local joined = table.concat(args, " ")
  assert(not joined:find("-m "), "should not have -m when model is nil, got: " .. joined)
  print("✓ build_agent_args without model omits -m")
end
test_agent_args_no_model()

print("\nAll work-sandbox tests passed!")
