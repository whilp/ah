#!/usr/bin/env cosmic
-- test_bash_sandbox.tl: test bash tool execution in sandbox environment

local sandbox = require("cosmic.sandbox")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

print("=== Bash Sandbox Test ===")

-- Apply sandbox (same as init.tl when AH_SANDBOX=1)
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
  sandbox.unveil("/dev/tty", "rw")
  sandbox.unveil("/proc/self", "r")
  local home = os.getenv("HOME")
  if home then
    sandbox.unveil(home, "r")
  end
  sandbox.unveil(nil, nil)

  local promises = "stdio rpath wpath cpath flock tty proc exec execnative unix prot_exec"
  sandbox.pledge(promises, promises, 2)
end

apply_sandbox()
print("sandbox applied")

-- Test 1: spawn with absolute paths works in sandbox
print("\nTest 1: absolute paths")
local all_env = env.all() as {string}
local handle, err = child.spawn(
  {"/usr/bin/timeout", "5", "/usr/bin/bash", "-c", "echo hello"},
  {env = all_env}
)
assert(handle, "spawn with absolute paths should succeed: " .. tostring(err))

local ok, stdout, exit_str = handle:read()
local exit_code = tonumber(exit_str) or -1
assert(exit_code == 0, "exit code should be 0, got " .. exit_code)
assert(stdout and stdout:match("hello"), "stdout should contain 'hello'")
print("✓ absolute paths work in sandbox")

-- Test 2: find_executable resolves paths correctly
print("\nTest 2: find_executable logic")

local function find_executable(name: string): string
  local env_override = os.getenv("AH_" .. name:upper())
  if env_override then
    return env_override
  end

  local common_paths: {string} = {
    "/usr/bin/" .. name,
    "/bin/" .. name,
    "/usr/local/bin/" .. name,
  }

  for _, path in ipairs(common_paths) do
    local f = io.open(path, "r")
    if f then
      f:close()
      return path
    end
  end

  return name
end

local bash_path = find_executable("bash")
local timeout_path = find_executable("timeout")

assert(bash_path:match("^/"), "bash should resolve to absolute path: " .. bash_path)
assert(timeout_path:match("^/"), "timeout should resolve to absolute path: " .. timeout_path)
print("✓ find_executable resolves: bash=" .. bash_path .. ", timeout=" .. timeout_path)

-- Test 3: resolved paths work in sandbox
print("\nTest 3: resolved paths in sandbox")
local handle2, err2 = child.spawn(
  {timeout_path, "5", bash_path, "-c", "echo resolved"},
  {env = all_env}
)
assert(handle2, "spawn with resolved paths should succeed: " .. tostring(err2))

local ok2, stdout2, exit_str2 = handle2:read()
local exit_code2 = tonumber(exit_str2) or -1
assert(exit_code2 == 0, "exit code should be 0, got " .. exit_code2)
assert(stdout2 and stdout2:match("resolved"), "stdout should contain 'resolved'")
print("✓ resolved paths work in sandbox")

print("\n=== All tests passed ===")
