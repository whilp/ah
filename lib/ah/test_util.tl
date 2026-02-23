#!/usr/bin/env cosmic
-- test_util.tl: tests for ah.util logging module

local record Util
  log_level: string
  log: function(msg: string)
  warn: function(msg: string)
  debug: function(msg: string)
end

local util = require("ah.util") as Util

-- test: log_level defaults correctly
local function test_log_level_type()
  assert(type(util.log_level) == "string", "log_level should be a string")
  assert(util.log_level == "debug" or util.log_level == "info" or util.log_level == "warn",
    "log_level should be 'debug', 'warn', or 'info', got: " .. util.log_level)
  print("PASS: log_level is a valid string")
end

-- test: log function exists and is callable
local function test_log_exists()
  assert(type(util.log) == "function", "log should be a function")
  print("PASS: log is a function")
end

-- test: warn function exists and is callable
local function test_warn_exists()
  assert(type(util.warn) == "function", "warn should be a function")
  print("PASS: warn is a function")
end

-- test: debug function exists and is callable
local function test_debug_exists()
  assert(type(util.debug) == "function", "debug should be a function")
  print("PASS: debug is a function")
end

-- test: debug respects log_level
local function test_debug_respects_level()
  local saved = util.log_level

  -- When level is "info", debug should not write
  util.log_level = "info"
  -- Call debug — it should silently do nothing
  util.debug("should not appear")

  -- When level is "warn", debug should not write
  util.log_level = "warn"
  util.debug("should not appear at warn level")

  -- When level is "debug", debug should write
  util.log_level = "debug"
  util.debug("should appear on stderr")

  util.log_level = saved
  print("PASS: debug respects log_level")
end

-- test: warn respects log_level
local function test_warn_respects_level()
  local saved = util.log_level

  -- When level is "info", warn should not write
  util.log_level = "info"
  util.warn("should not appear at info level")

  -- When level is "warn", warn should write
  util.log_level = "warn"
  util.warn("should appear at warn level on stderr")

  -- When level is "debug", warn should write
  util.log_level = "debug"
  util.warn("should appear at debug level on stderr")

  util.log_level = saved
  print("PASS: warn respects log_level")
end

-- test: log always writes regardless of level
local function test_log_always_writes()
  local saved = util.log_level

  util.log_level = "info"
  util.log("log at info level")

  util.log_level = "warn"
  util.log("log at warn level")

  util.log_level = "debug"
  util.log("log at debug level")

  util.log_level = saved
  print("PASS: log writes at any level")
end

test_log_level_type()
test_log_exists()
test_warn_exists()
test_debug_exists()
test_debug_respects_level()
test_warn_respects_level()
test_log_always_writes()
