#!/usr/bin/env cosmic
-- test_sandbox_exec.tl: verify that native commands can be executed inside the sandbox
--
-- The sandbox applies pledge/unveil restrictions. Native Linux binaries
-- (dynamically linked) need prot_exec to allow mmap(PROT_EXEC) for the
-- dynamic linker. Without it, all commands fail with exit code 127.

local sandbox = require("cosmic.sandbox")
local child = require("cosmic.child")
local env = require("cosmic.env")
local cfs = require("cosmic.fs")

-- Helper: fork a child, apply sandbox, run a command, report exit code.
-- Returns the child's exit code (0 = success, non-zero = failure).
local function sandbox_exec(cmd: {string}, promises: string): integer
  local pid = child.fork()
  assert(pid >= 0, "fork failed")

  if pid == 0 then
    -- Child: apply sandbox restrictions matching init.tl
    local cwd = cfs.getcwd()
    sandbox.unveil(cwd, "rwxc")
    sandbox.unveil("/tmp", "rwc")
    sandbox.unveil("/usr", "rx")
    sandbox.unveil("/bin", "rx")
    sandbox.unveil("/lib", "rx")
    sandbox.unveil("/lib64", "rx")
    sandbox.unveil("/etc/ssl", "r")
    sandbox.unveil("/etc/resolv.conf", "r")
    sandbox.unveil("/dev/null", "rw")
  sandbox.unveil("/dev/tty", "rw")
  sandbox.unveil("/proc/self", "r")
    local home = os.getenv("HOME")
    if home then
      sandbox.unveil(home, "r")
    end
    sandbox.unveil(nil, nil)

    sandbox.pledge(promises, promises, 2)

    local handle = child.spawn(cmd, {env = env.all() as {string}})
    if not handle then
      os.exit(42)
    end
    local ok, stdout, exit_str = handle:read()
    local exit_code = (tonumber(exit_str) or 0) as integer
    os.exit(exit_code)
  end

  -- Parent: wait for child and extract exit code
  -- On POSIX, exit status is encoded as (code << 8); shift to get the real code.
  local _, raw_status = child.wait()
  local status_int = (raw_status as integer) or 0
  -- WEXITSTATUS: shift right by 8 to extract exit code from wait status
  local exit_code = (math.floor(status_int / 256)) as integer
  return exit_code
end

-- Read the actual pledge promises from init.tl to test the real configuration
local function read_init_promises(): string
  local f = io.open("lib/ah/init.tl", "r")
  if not f then
    f = io.open("../../../lib/ah/init.tl", "r")
  end
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  -- Extract: local promises = "stdio rpath ..."
  local promises = content:match('local promises = "([^"]+)"')
  return promises
end

-- Test: echo command works inside sandbox with current init.tl promises
local function test_sandbox_echo()
  local promises = read_init_promises()
  assert(promises, "should be able to read pledge promises from init.tl")

  local exit_code = sandbox_exec({"echo", "hello"}, promises)
  assert(exit_code == 0,
    "echo should succeed inside sandbox, got exit code " .. tostring(exit_code) ..
    "\npromises: " .. promises)
  print("✓ echo works inside sandbox")
end
test_sandbox_echo()

-- Test: bash -c works inside sandbox (this is what the bash tool uses)
local function test_sandbox_bash()
  local promises = read_init_promises()
  assert(promises, "should be able to read pledge promises from init.tl")

  local exit_code = sandbox_exec({"bash", "-c", "echo hello"}, promises)
  assert(exit_code == 0,
    "bash -c should succeed inside sandbox, got exit code " .. tostring(exit_code) ..
    "\npromises: " .. promises)
  print("✓ bash -c works inside sandbox")
end
test_sandbox_bash()

-- Test: timeout + bash works inside sandbox (exact argv from bash tool)
local function test_sandbox_timeout_bash()
  local promises = read_init_promises()
  assert(promises, "should be able to read pledge promises from init.tl")

  local exit_code = sandbox_exec({"timeout", "5", "bash", "-c", "echo hello"}, promises)
  assert(exit_code == 0,
    "timeout + bash should succeed inside sandbox, got exit code " .. tostring(exit_code) ..
    "\npromises: " .. promises)
  print("✓ timeout + bash works inside sandbox")
end
test_sandbox_timeout_bash()

-- Test: file read works inside sandbox
local function test_sandbox_file_read()
  local promises = read_init_promises()
  assert(promises, "should be able to read pledge promises from init.tl")

  -- Write a file first (outside sandbox), then read it inside
  local test_path = "/tmp/sandbox_read_test_" .. tostring(os.time()) .. ".txt"
  local wf = io.open(test_path, "w")
  assert(wf, "should be able to write test file")
  wf:write("sandbox test content\n")
  wf:close()

  local exit_code = sandbox_exec({"cat", test_path}, promises)
  os.remove(test_path)
  assert(exit_code == 0,
    "cat should succeed inside sandbox, got exit code " .. tostring(exit_code) ..
    "\npromises: " .. promises)
  print("✓ file read (cat) works inside sandbox")
end
test_sandbox_file_read()

-- Test: child.spawn with stdin=nil blocks (child never gets EOF)
-- This is the bug that caused the check phase to hang for 3 minutes.
-- cat reads stdin until EOF; with stdin=nil it inherits an open pipe
-- that is never closed, so it blocks forever.
local function test_spawn_stdin_nil_blocks()
  local pid = child.fork()
  assert(pid >= 0, "fork failed")

  if pid == 0 then
    -- Child: spawn cat with stdin=nil, expect it to block
    local handle = child.spawn({"cat"}, {stdin = nil})
    if not handle then os.exit(42) end
    -- This read should block because cat never gets EOF.
    -- The parent will kill us after 2 seconds.
    handle:read()
    -- If we get here, stdin=nil did NOT block (test should fail)
    os.exit(0)
  end

  -- Parent: wait 2 seconds, then check if child is still running.
  -- If it is, stdin=nil caused the expected block.
  local time = require("cosmic.time")
  time.sleep(2, 0)

  local signal = require("cosmic.signal")
  -- Try to kill the child — if it's still alive, the test passes
  local kill_ok = signal.kill(pid, child.SIGKILL)
  local _, raw_status = child.wait()
  local exit_code = (math.floor(((raw_status as integer) or 0) / 256)) as integer

  -- kill_ok true means child was still running (blocked as expected)
  -- exit_code 137 (128+9) or 9 means killed by SIGKILL
  assert(kill_ok, "child should still be alive (blocked on stdin=nil)")
  print("✓ child.spawn with stdin=nil blocks (as expected)")
end
test_spawn_stdin_nil_blocks()

-- Test: child.spawn with stdin="" exits cleanly (child gets immediate EOF)
-- This is the fix: passing "" creates a pipe that is immediately closed,
-- so the child's read gets EOF and exits.
local function test_spawn_stdin_empty_exits()
  local handle = child.spawn({"cat"}, {stdin = ""})
  assert(handle, "spawn should succeed")
  local ok, stdout, exit_str = handle:read()
  local exit_code = (tonumber(exit_str) or 0) as integer
  assert(ok, "cat should exit cleanly with stdin=''")
  assert(exit_code == 0, "cat should exit 0, got: " .. tostring(exit_code))
  assert(stdout == "" or stdout == nil, "cat with empty stdin should produce no output")
  print("✓ child.spawn with stdin='' exits cleanly (EOF)")
end
test_spawn_stdin_empty_exits()

print("\nAll sandbox exec tests passed!")
