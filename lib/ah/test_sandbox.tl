#!/usr/bin/env cosmic
-- test_sandbox.tl: unit tests for env_set and env_get in ah.sandbox

local sandbox = require("ah.sandbox")

-- test: env_set appends when key is absent
local function test_env_set_appends()
  local env: {string} = {}
  sandbox.env_set(env, "FOO", "bar")
  assert(#env == 1, "env should have one entry, got " .. #env)
  assert(env[1] == "FOO=bar", "entry should be FOO=bar, got " .. tostring(env[1]))
  print("PASS: env_set appends when key absent")
end

-- test: env_set replaces when key is present
local function test_env_set_replaces()
  local env: {string} = {"FOO=original"}
  sandbox.env_set(env, "FOO", "updated")
  assert(#env == 1, "env should still have one entry, got " .. #env)
  assert(env[1] == "FOO=updated", "entry should be FOO=updated, got " .. tostring(env[1]))
  print("PASS: env_set replaces existing entry")
end

-- test: env_set replaces first match and leaves no duplicates
local function test_env_set_no_duplicates()
  local env: {string} = {"FOO=first", "BAR=other"}
  sandbox.env_set(env, "FOO", "second")
  assert(#env == 2, "env should still have two entries, got " .. #env)
  assert(env[1] == "FOO=second", "first entry should be FOO=second, got " .. tostring(env[1]))
  assert(env[2] == "BAR=other", "second entry should be BAR=other, got " .. tostring(env[2]))
  print("PASS: env_set produces no duplicates")
end

-- test: env_set does not match prefix-only keys (e.g. FOO vs FOOBAR)
local function test_env_set_no_prefix_collision()
  local env: {string} = {"FOOBAR=val"}
  sandbox.env_set(env, "FOO", "new")
  assert(#env == 2, "env should have two entries, got " .. #env)
  assert(env[2] == "FOO=new", "new entry should be FOO=new, got " .. tostring(env[2]))
  print("PASS: env_set does not match prefix-only keys")
end

-- test: env_get returns nil when key absent
local function test_env_get_absent()
  local env: {string} = {"BAR=baz"}
  local val = sandbox.env_get(env, "FOO")
  assert(val == nil, "env_get should return nil for absent key, got " .. tostring(val))
  print("PASS: env_get returns nil for absent key")
end

-- test: env_get returns value when key present
local function test_env_get_present()
  local env: {string} = {"FOO=hello"}
  local val = sandbox.env_get(env, "FOO")
  assert(val == "hello", "env_get should return 'hello', got " .. tostring(val))
  print("PASS: env_get returns value for present key")
end

-- test: env_get returns first match
local function test_env_get_first_match()
  local env: {string} = {"FOO=first", "FOO=second"}
  local val = sandbox.env_get(env, "FOO")
  assert(val == "first", "env_get should return first match, got " .. tostring(val))
  print("PASS: env_get returns first match")
end

test_env_set_appends()
test_env_set_replaces()
test_env_set_no_duplicates()
test_env_set_no_prefix_collision()
test_env_get_absent()
test_env_get_present()
test_env_get_first_match()

print("\n7 checks: 7 passed")
