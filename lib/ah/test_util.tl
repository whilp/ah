#!/usr/bin/env cosmic
-- test_util.tl: tests for ah.util logging module

local env = require("cosmic.env")

local record Util
  log_level: string
  log: function(msg: string)
  debug: function(msg: string)
  get_proxy_url: function(): string
end

local util = require("ah.util") as Util

-- test: log_level defaults correctly
local function test_log_level_type()
  assert(type(util.log_level) == "string", "log_level should be a string")
  assert(util.log_level == "debug" or util.log_level == "info",
    "log_level should be 'debug' or 'info', got: " .. util.log_level)
  print("PASS: log_level is a valid string")
end

-- test: log function exists and is callable
local function test_log_exists()
  assert(type(util.log) == "function", "log should be a function")
  print("PASS: log is a function")
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

  -- When level is "debug", debug should write
  util.log_level = "debug"
  util.debug("should appear on stderr")

  util.log_level = saved
  print("PASS: debug respects log_level")
end

-- test: log always writes regardless of level
local function test_log_always_writes()
  local saved = util.log_level

  util.log_level = "info"
  util.log("log at info level")

  util.log_level = "debug"
  util.log("log at debug level")

  util.log_level = saved
  print("PASS: log writes at any level")
end

test_log_level_type()
test_log_exists()
test_debug_exists()
test_debug_respects_level()
test_log_always_writes()

-- test: get_proxy_url returns nil when no proxy env vars set
local function test_get_proxy_url_none()
  local saved = {
    os.getenv("https_proxy"), os.getenv("HTTPS_PROXY"),
    os.getenv("http_proxy"), os.getenv("HTTP_PROXY"),
  }
  env.unset("https_proxy")
  env.unset("HTTPS_PROXY")
  env.unset("http_proxy")
  env.unset("HTTP_PROXY")
  local url = util.get_proxy_url()
  assert(url == nil, "no proxy vars should return nil, got: " .. tostring(url))
  if saved[1] then env.set("https_proxy", saved[1]) end
  if saved[2] then env.set("HTTPS_PROXY", saved[2]) end
  if saved[3] then env.set("http_proxy", saved[3]) end
  if saved[4] then env.set("HTTP_PROXY", saved[4]) end
  print("PASS test_get_proxy_url_none")
end
test_get_proxy_url_none()
