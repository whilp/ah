#!/usr/bin/env cosmic
-- test_sandbox.tl: tests for ah.work.sandbox module

local record AgentLimits
  max_tokens: integer
  timeout_sec: integer
end

local record PhaseOpts
  sandbox: boolean
  timeout: integer
  unveil_dirs: {string}
  db: string
  prompt: string
  max_tokens: integer
  model: string
end

local record WorkSandbox
  build_phase_args: function(string, PhaseOpts): {string}
end

local sandbox = require("ah.work.sandbox") as WorkSandbox

-- Helper: join args for assertion messages
local function joined(args: {string}): string
  return table.concat(args, " ")
end

-- Test: build_phase_args basic (no sandbox, no limits)
local function test_phase_args_basic()
  local args = sandbox.build_phase_args("ah", {
    db = "test.db",
    prompt = "hello",
  })
  assert(args[1] == "ah", "exe should be ah, got: " .. args[1])
  assert(args[2] == "-n", "should have -n for new session, got: " .. args[2])
  assert(args[3] == "--db", "should have --db, got: " .. args[3])
  assert(args[4] == "test.db", "should have db path, got: " .. args[4])
  assert(#args == 4, "should have 4 args (no prompt in argv), got: " .. #args)
  print("✓ build_phase_args basic")
end
test_phase_args_basic()

-- Test: build_phase_args with sandbox flag
local function test_phase_args_sandbox()
  local args = sandbox.build_phase_args("ah", {
    sandbox = true,
    db = "test.db",
    prompt = "hello",
  })
  local j = joined(args)
  assert(j:find("--sandbox"), "should have --sandbox, got: " .. j)
  print("✓ build_phase_args with sandbox")
end
test_phase_args_sandbox()

-- Test: build_phase_args with max_tokens
local function test_phase_args_max_tokens()
  local args = sandbox.build_phase_args("ah", {
    db = "test.db",
    prompt = "hello",
    max_tokens = 50000,
  })
  local j = joined(args)
  assert(j:find("--max%-tokens 50000"), "should have --max-tokens 50000, got: " .. j)
  -- prompt should NOT be in argv
  assert(args[#args] ~= "hello", "prompt should not be in argv, got: " .. args[#args])
  print("✓ build_phase_args with max_tokens")
end
test_phase_args_max_tokens()

-- Test: build_phase_args with timeout wraps in timeout command
local function test_phase_args_timeout()
  local args = sandbox.build_phase_args("ah", {
    db = "test.db",
    prompt = "hello",
    timeout = 300,
  })
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "300", "should have timeout seconds, got: " .. args[2])
  assert(args[3] == "ah", "exe should follow timeout, got: " .. args[3])
  print("✓ build_phase_args with timeout")
end
test_phase_args_timeout()

-- Test: build_phase_args with both limits
local function test_phase_args_both_limits()
  local args = sandbox.build_phase_args("ah", {
    sandbox = true,
    db = "test.db",
    prompt = "hello",
    max_tokens = 100000,
    timeout = 300,
  })
  local j = joined(args)
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "300", "timeout value, got: " .. args[2])
  assert(j:find("--max%-tokens 100000"), "should have --max-tokens, got: " .. j)
  assert(j:find("--sandbox"), "should have --sandbox, got: " .. j)
  print("✓ build_phase_args with both limits")
end
test_phase_args_both_limits()

-- Test: build_phase_args with model
local function test_phase_args_model()
  local args = sandbox.build_phase_args("ah", {
    db = "test.db",
    prompt = "hello",
    model = "opus",
  })
  local j = joined(args)
  assert(j:find("-m opus"), "should have -m opus, got: " .. j)
  assert(args[1] == "ah")
  print("✓ build_phase_args with model")
end
test_phase_args_model()

-- Test: build_phase_args with model and limits
local function test_phase_args_model_and_limits()
  local args = sandbox.build_phase_args("ah", {
    sandbox = true,
    db = "test.db",
    prompt = "hello",
    max_tokens = 50000,
    timeout = 180,
    model = "haiku",
  })
  local j = joined(args)
  assert(args[1] == "timeout", "should start with timeout, got: " .. args[1])
  assert(args[2] == "180", "timeout value, got: " .. args[2])
  assert(j:find("-m haiku"), "should have -m haiku, got: " .. j)
  assert(j:find("--max%-tokens 50000"), "should have --max-tokens, got: " .. j)
  print("✓ build_phase_args with model and limits")
end
test_phase_args_model_and_limits()

-- Test: build_phase_args without model (nil) doesn't add -m
local function test_phase_args_no_model()
  local args = sandbox.build_phase_args("ah", {
    db = "test.db",
    prompt = "hello",
  })
  local j = joined(args)
  assert(not j:find("-m "), "should not have -m when model is nil, got: " .. j)
  print("✓ build_phase_args without model omits -m")
end
test_phase_args_no_model()

-- Test: build_phase_args with unveil_dirs
local function test_phase_args_unveil()
  local args = sandbox.build_phase_args("ah", {
    sandbox = true,
    db = "test.db",
    prompt = "hello",
    unveil_dirs = {"o/work/plan", "o/work/do"},
  })
  local j = joined(args)
  assert(j:find("--unveil o/work/plan:r"), "should have --unveil o/work/plan:r, got: " .. j)
  assert(j:find("--unveil o/work/do:r"), "should have --unveil o/work/do:r, got: " .. j)
  print("✓ build_phase_args with unveil_dirs")
end
test_phase_args_unveil()

-- Test: prompt is NOT included in argv (piped via stdin instead)
local function test_phase_args_no_prompt_in_argv()
  local long_prompt = string.rep("x", 10000)
  local args = sandbox.build_phase_args("ah", {
    db = "test.db",
    prompt = long_prompt,
    timeout = 180,
  })
  for _, a in ipairs(args) do
    assert(a ~= long_prompt, "prompt should not appear in argv")
  end
  print("✓ build_phase_args excludes prompt from argv")
end
test_phase_args_no_prompt_in_argv()

print("\nAll work-sandbox tests passed!")
