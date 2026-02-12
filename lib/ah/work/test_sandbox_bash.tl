#!/usr/bin/env cosmic
-- test_sandbox_bash.tl: diagnostic test for bash execution in sandbox
--
-- This test verifies bash tool execution inside the sandbox.
-- It should be run in CI to diagnose the "exit code 127" issue.

local sandbox = require("cosmic.sandbox")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

print("=== Sandbox Bash Diagnostic Test ===\n")

-- Log system info
print("1. System Information:")
print("   cwd: " .. fs.getcwd())
print("   HOME: " .. (os.getenv("HOME") or "(not set)"))
print("   AH_SANDBOX: " .. (os.getenv("AH_SANDBOX") or "(not set)"))

-- Log PATH
print("\n2. PATH Environment:")
local all_env = env.all() as {string}
for _, v in ipairs(all_env) do
  if v:match("^PATH=") then
    print("   " .. v)
    break
  end
end

-- Test before sandbox
print("\n3. Before Sandbox - Testing spawn:")
local function test_spawn(desc: string, cmd: {string}): boolean, integer, string
  local handle, err = child.spawn(cmd, {env = all_env})
  if not handle then
    print("   " .. desc .. ": SPAWN FAILED - " .. tostring(err))
    return false, -1, ""
  end
  local ok, stdout, exit_str = handle:read()
  local exit_code = tonumber(exit_str) as integer or -1
  local stdout_str = (stdout as string) or ""
  local status = exit_code == 0 and "OK" or "FAIL"
  print("   " .. desc .. ": " .. status .. " (exit=" .. exit_code .. ", stdout_len=" .. #stdout_str .. ")")
  if exit_code ~= 0 and #stdout_str > 0 then
    print("     stdout: " .. stdout_str:sub(1, 100))
  end
  return ok as boolean, exit_code, stdout_str
end

test_spawn("echo hello", {"echo", "hello"})
test_spawn("bash -c echo", {"bash", "-c", "echo hello"})
test_spawn("timeout 1 echo", {"timeout", "1", "echo", "hello"})
test_spawn("timeout 1 bash -c echo", {"timeout", "1", "bash", "-c", "echo hello"})

-- Check binary locations
print("\n4. Binary Locations:")
test_spawn("which bash", {"which", "bash"})
test_spawn("which timeout", {"which", "timeout"})
test_spawn("ls -la /usr/bin/bash", {"ls", "-la", "/usr/bin/bash"})
test_spawn("ls -la /usr/bin/timeout", {"ls", "-la", "/usr/bin/timeout"})

-- Apply sandbox
print("\n5. Applying Sandbox Restrictions:")
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
print("   unveil: committed")

local promises = "stdio rpath wpath cpath flock tty proc exec unix prot_exec"
sandbox.pledge(promises, promises, 2)
print("   pledge: " .. promises)

-- Test after sandbox
print("\n6. After Sandbox - Testing spawn:")
test_spawn("echo hello", {"echo", "hello"})
test_spawn("bash -c echo", {"bash", "-c", "echo hello"})
test_spawn("timeout 1 echo", {"timeout", "1", "echo", "hello"})
test_spawn("timeout 1 bash -c echo", {"timeout", "1", "bash", "-c", "echo hello"})

-- Test the exact command the bash tool uses
print("\n7. Bash Tool Command Pattern:")
local shell = os.getenv("AH_SHELL") or "bash"
print("   shell: " .. shell)
local _ok, exit_code, _stdout = test_spawn(
  "timeout 120 " .. shell .. " -c 'echo test; echo PATH=$PATH'",
  {"timeout", "120", shell, "-c", "echo test; echo PATH=$PATH"}
)

if exit_code == 127 then
  print("\n!!! EXIT CODE 127 DETECTED !!!")
  print("This indicates 'command not found'. Possible causes:")
  print("1. PATH not propagating correctly")
  print("2. Shell binary not accessible after unveil")
  print("3. Dynamic linker not accessible")
  
  -- Try with absolute paths
  print("\n8. Testing with absolute paths:")
  test_spawn("/usr/bin/bash -c echo", {"/usr/bin/bash", "-c", "echo hello"})
  test_spawn("/usr/bin/timeout 1 /usr/bin/bash -c echo", 
    {"/usr/bin/timeout", "1", "/usr/bin/bash", "-c", "echo hello"})
end

print("\n=== Test Complete ===")
