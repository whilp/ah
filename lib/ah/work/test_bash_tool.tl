#!/usr/bin/env cosmic
-- test_bash_tool.tl: test that bash tool works inside sandbox
--
-- This test verifies that:
-- 1. The bash tool can execute commands inside the sandbox
-- 2. Exit codes are captured correctly
-- 3. Output is captured correctly

local sandbox = require("cosmic.sandbox")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

-- Helper: apply sandbox restrictions matching init.tl
local function apply_sandbox()
  local cwd = fs.getcwd()
  sandbox.unveil(cwd, "rwxc")
  sandbox.unveil("/tmp", "rwc")
  sandbox.unveil("/usr", "rx")
  sandbox.unveil("/bin", "rx")
  sandbox.unveil("/lib", "rx")
  sandbox.unveil("/lib64", "rx")
  sandbox.unveil("/etc/ssl", "r")
  sandbox.unveil("/etc/resolv.conf", "r")
  sandbox.unveil("/dev/null", "rw")
  local home = os.getenv("HOME")
  if home then
    sandbox.unveil(home, "r")
  end
  sandbox.unveil(nil, nil)

  local promises = "stdio rpath wpath cpath flock tty proc exec unix prot_exec"
  sandbox.pledge(promises, promises, 2)
end

-- Test 1: basic command execution with relative path
local function test_bash_relative_path()
  apply_sandbox()
  
  local shell = os.getenv("AH_SHELL") or "bash"
  local all_env = env.all() as {string}
  
  -- This mirrors what the bash tool does
  local handle, err = child.spawn(
    {"timeout", "5", shell, "-c", "echo hello"},
    {env = all_env}
  )
  assert(handle, "spawn should succeed: " .. tostring(err))
  
  local ok, stdout, exit_str = handle:read()
  local exit_code = tonumber(exit_str) or -1
  
  assert(exit_code == 0, 
    "command should succeed, got exit code " .. tostring(exit_code) ..
    " stdout=[" .. tostring(stdout) .. "]")
  assert(stdout:match("hello"), "should output 'hello', got: " .. tostring(stdout))
  
  print("✓ bash with relative path works inside sandbox")
end

-- Test 2: verify exit code 127 handling
local function test_command_not_found()
  -- Don't apply sandbox again (already applied in test_bash_relative_path)
  
  local all_env = env.all() as {string}
  
  -- Try to run a command that doesn't exist
  local handle = child.spawn(
    {"timeout", "5", "nonexistent_shell_xyz", "-c", "echo hello"},
    {env = all_env}
  )
  assert(handle, "spawn should succeed even for missing command")
  
  local ok, stdout, exit_str = handle:read()
  local exit_code = tonumber(exit_str) or -1
  
  assert(exit_code == 127, 
    "should get exit code 127 for missing command, got " .. tostring(exit_code))
  
  print("✓ exit code 127 for missing command")
end

-- Test 3: verify env.all() has PATH
local function test_env_has_path()
  local all_env = env.all() as {string}
  local has_path = false
  for _, v in ipairs(all_env) do
    if v:match("^PATH=") then
      has_path = true
      print("  PATH=" .. v:sub(6, 80) .. "...")
      break
    end
  end
  assert(has_path, "env.all() should include PATH")
  print("✓ env.all() includes PATH")
end

-- Run tests
test_env_has_path()
test_bash_relative_path()
test_command_not_found()

print("\nAll bash tool tests passed!")
