#!/usr/bin/env cosmic
-- test_sandbox_make.tl: test that make can run inside sandbox

local env = require("cosmic.env")
local child = require("cosmic.child")
local sandbox = require("cosmic.sandbox")
local fs = require("cosmic.fs")

-- Test that make can spawn bash subprocesses when sandbox is active
local function test_make_in_sandbox()
  -- Save current directory
  local cwd = fs.getcwd()
  
  -- Set up sandbox similar to how ah does it
  sandbox.unveil(cwd, "rwxc")
  sandbox.unveil("/tmp", "rwc")
  sandbox.unveil("/usr", "rx")
  sandbox.unveil("/bin", "rx")
  sandbox.unveil("/lib", "rx")
  sandbox.unveil("/lib64", "rx")
  sandbox.unveil("/etc/ssl", "r")
  sandbox.unveil("/etc/resolv.conf", "r")
  sandbox.unveil("/dev/null", "rw")
  sandbox.unveil("/dev/tty", "rw")          -- terminal access
  sandbox.unveil("/proc/self", "r")         -- bash and make need /proc/self
  local home = os.getenv("HOME")
  if home then
    sandbox.unveil(home, "r")
  end
  sandbox.unveil(nil, nil)  -- commit unveil
  
  -- Apply pledge with same promises as work sandbox
  local PLEDGE_PENALTY_RETURN_EPERM = 2
  local promises = "stdio rpath wpath cpath flock tty proc exec execnative unix prot_exec"
  sandbox.pledge(promises, promises, PLEDGE_PENALTY_RETURN_EPERM)
  
  -- Now try to run make --version (simple test that doesn't need full build)
  local handle, err = child.spawn({"/usr/bin/make", "--version"}, {env = env.all() as {string}})
  if not handle then
    print("FAIL: could not spawn make: " .. tostring(err))
    os.exit(1)
  end
  
  local ok, stdout, exit_str = handle:read()
  local exit_code = tonumber(exit_str) or 0
  
  if exit_code ~= 0 then
    print("FAIL: make --version failed with exit code " .. tostring(exit_code))
    print("stdout: " .. tostring(stdout))
    os.exit(1)
  end
  
  if not stdout or not stdout:match("GNU Make") then
    print("FAIL: make --version did not return expected output")
    print("stdout: " .. tostring(stdout))
    os.exit(1)
  end
  
  print("✓ make --version works in sandbox")
end

-- Test that make can run a simple target
local function test_make_target_in_sandbox()
  -- Create a temp Makefile
  local tmpdir = os.getenv("TMPDIR") or "/tmp"
  local test_dir = tmpdir .. "/ah-sandbox-make-test-" .. tostring(os.time())
  fs.makedirs(test_dir)
  
  local makefile = test_dir .. "/Makefile"
  local f = io.open(makefile, "w")
  -- Use /bin/bash (standard location, matches ah's Makefile)
  f:write("SHELL := /bin/bash\ntest:\n\techo hello from bash\n")
  f:close()
  
  -- Run make in that directory with stderr redirected to stdout
  local handle, err = child.spawn(
    {"/bin/bash", "-c", "/usr/bin/make -C " .. test_dir .. " test 2>&1"},
    {env = env.all() as {string}}
  )
  
  if not handle then
    print("FAIL: could not spawn make: " .. tostring(err))
    os.exit(1)
  end
  
  local ok, stdout, exit_str = handle:read()
  local exit_code = tonumber(exit_str) or 0
  
  -- Clean up
  os.remove(makefile)
  os.remove(test_dir)
  
  if exit_code ~= 0 then
    print("FAIL: make test failed with exit code " .. tostring(exit_code))
    print("stdout: " .. tostring(stdout))
    os.exit(1)
  end
  
  if not stdout or not stdout:match("hello") then
    print("FAIL: make test did not produce expected output")
    print("stdout: " .. tostring(stdout))
    os.exit(1)
  end
  
  print("✓ make target with bash shell works in sandbox")
end

-- Run tests
print("Testing make in sandbox...")
-- Note: we can only test unveil/pledge once per process, so we test
-- the simpler case first. In production, make spawning bash is the issue.
test_make_in_sandbox()
test_make_target_in_sandbox()

print("\nAll sandbox make tests passed!")
