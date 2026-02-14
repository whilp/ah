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
  prepare_child_stdin: function(): string
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

-- Test: prepare_child_stdin never returns nil
-- This is the contract that prevents the sandbox child from blocking forever.
-- When stdin is /dev/null, prepare_child_stdin must return "" (not nil),
-- because child.spawn({stdin = nil}) creates an unclosed pipe that blocks.
local function test_prepare_child_stdin_never_nil()
  local child = require("cosmic.child")

  -- Fork so we can redirect stdin to /dev/null without affecting the test runner
  local pid = child.fork()
  assert(pid >= 0, "fork failed")

  if pid == 0 then
    -- Child: reopen stdin from /dev/null, then call prepare_child_stdin
    local fd = io.open("/dev/null", "r")
    if not fd then os.exit(10) end
    -- Replace stdin: close fd 0, dup /dev/null to fd 0
    io.stdin:close()
    io.input(fd)

    local result = sandbox.prepare_child_stdin()
    if result == nil then
      os.exit(1)  -- FAIL: returned nil
    end
    if type(result) ~= "string" then
      os.exit(2)  -- FAIL: not a string
    end
    os.exit(0)  -- PASS
  end

  -- Parent: wait for child
  local _, raw_status = child.wait()
  local exit_code = (math.floor(((raw_status as integer) or 0) / 256)) as integer
  assert(exit_code == 0,
    "prepare_child_stdin returned nil or non-string when stdin is /dev/null (exit " .. tostring(exit_code) .. ")")
  print("✓ prepare_child_stdin never returns nil (stdin=/dev/null)")
end
test_prepare_child_stdin_never_nil()

-- Test: prepare_child_stdin returns data when stdin has content
local function test_prepare_child_stdin_with_data()
  local child = require("cosmic.child")
  local cfs = require("cosmic.fs")

  -- Write test data to a temp file, then use it as stdin
  local tmp = "/tmp/ah_test_stdin_" .. tostring(os.time()) .. ".txt"
  local f = io.open(tmp, "w")
  assert(f, "failed to create temp file")
  f:write("test input data")
  f:close()

  local pid = child.fork()
  assert(pid >= 0, "fork failed")

  if pid == 0 then
    local fd = io.open(tmp, "r")
    if not fd then os.exit(10) end
    io.stdin:close()
    io.input(fd)

    local result = sandbox.prepare_child_stdin()
    if result ~= "test input data" then
      os.exit(1)
    end
    os.exit(0)
  end

  local _, raw_status = child.wait()
  local exit_code = (math.floor(((raw_status as integer) or 0) / 256)) as integer
  os.remove(tmp)
  assert(exit_code == 0,
    "prepare_child_stdin should return stdin data, exit " .. tostring(exit_code))
  print("✓ prepare_child_stdin returns data when stdin has content")
end
test_prepare_child_stdin_with_data()

print("\nAll work-sandbox tests passed!")
