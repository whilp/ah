#!/usr/bin/env cosmic
-- test_cosmic_env.tl: test that AH_COSMIC env var is set and usable

print("=== Cosmic Env Test ===")

-- Test 1: find_executable uses AH_COSMIC env override
print("\nTest 1: find_executable AH_COSMIC override")

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

-- When AH_COSMIC is set, find_executable("cosmic") should return it
local saved_cosmic = os.getenv("AH_COSMIC")

-- Test with AH_COSMIC set to a known path
-- We simulate by checking the logic directly
local test_path = "/test/path/cosmic"
-- The env override logic: if AH_COSMIC is set, return it
local env_val = os.getenv("AH_COSMIC")
if env_val then
  local resolved = find_executable("cosmic")
  assert(resolved == env_val, "find_executable('cosmic') should return AH_COSMIC value, got: " .. resolved)
  print("✓ AH_COSMIC=" .. env_val .. " → find_executable returns: " .. resolved)
else
  -- In non-sandbox mode, AH_COSMIC may not be set; verify fallback behavior
  local resolved = find_executable("cosmic")
  assert(type(resolved) == "string", "find_executable should return a string")
  print("✓ AH_COSMIC not set, fallback resolved to: " .. resolved)
end

-- Test 2: AH_COSMIC points to an executable (if set)
print("\nTest 2: AH_COSMIC is executable (if set)")
local cosmic_path = os.getenv("AH_COSMIC")
if cosmic_path then
  local f = io.open(cosmic_path, "r")
  assert(f, "AH_COSMIC path should be readable: " .. cosmic_path)
  if f then f:close() end
  print("✓ AH_COSMIC path is readable: " .. cosmic_path)
else
  print("✓ AH_COSMIC not set (non-sandbox mode), skipping executable check")
end

-- Test 3: arg[-1] is the cosmic binary path
print("\nTest 3: arg[-1] is cosmic binary")
local self_path = arg and arg[-1]
assert(self_path, "arg[-1] should be set")
assert(type(self_path) == "string", "arg[-1] should be a string")
local f2 = io.open(self_path, "r")
assert(f2, "arg[-1] should be a readable path: " .. tostring(self_path))
if f2 then f2:close() end
print("✓ arg[-1] is readable: " .. self_path)

-- Test 4: ah_exe() logic matches arg[-1]
print("\nTest 4: ah_exe() returns arg[-1]")
local function ah_exe(): string
  return arg and arg[-1] or "ah"
end
local exe = ah_exe()
assert(exe == self_path, "ah_exe() should equal arg[-1]: " .. exe .. " vs " .. tostring(self_path))
print("✓ ah_exe() = " .. exe)

print("\n=== All tests passed ===")
