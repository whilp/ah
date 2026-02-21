-- test_version: verify --version flag handling
local ah = require("ah")

local function test_version_flag()
  -- --version should return exit code 0
  local code, err = ah.main({"--version"})
  assert(code == 0, "expected exit 0, got " .. tostring(code))
  assert(not err, "expected no error, got " .. tostring(err))
  print("PASS: --version returns 0")
end

local function test_short_version_flag()
  -- -V should return exit code 0
  local code, err = ah.main({"-V"})
  assert(code == 0, "expected exit 0, got " .. tostring(code))
  assert(not err, "expected no error, got " .. tostring(err))
  print("PASS: -V returns 0")
end

local function test_version_in_usage()
  local ah_bin = os.getenv("AH_BIN")
  assert(ah_bin, "AH_BIN not set — need built binary")
  local f = io.popen(ah_bin .. " --help 2>&1")
  assert(f, "failed to run ah --help")
  local text = f:read("*a") as string
  f:close()
  assert(text:find("%-V"), "usage should mention -V flag")
  assert(text:find("%-%-version"), "usage should mention --version flag")
  print("PASS: usage mentions --version")
end

test_version_flag()
test_short_version_flag()
test_version_in_usage()
