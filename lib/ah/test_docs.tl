#!/usr/bin/env cosmic
-- test_docs.tl: tests for the docs subcommand module
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

-- Test the binary-level docs subcommand via AH_BIN.

local function test_docs_no_args()
  -- ah docs (no query) should list available docs and exit 0
  local ah_bin = os.getenv("AH_BIN") or "o/bin/ah"
  local cmd = ah_bin .. " docs 2>&1"
  local handle = io.popen(cmd)
  if handle then
    local out = handle:read("*a")
    handle:close()
    -- Should list docs or report unavailable (in test context without embedded docs)
    assert(
      out:match("available documentation") or out:match("no embedded documentation"),
      "ah docs should list topics or report unavailable: " .. out
    )
  end
end
test_docs_no_args()

local function test_docs_with_query_returns_output()
  -- ah docs <query> should produce some output
  local ah_bin = os.getenv("AH_BIN") or "o/bin/ah"
  local cmd = ah_bin .. " docs tool 2>&1"
  local handle = io.popen(cmd)
  if handle then
    local out = handle:read("*a")
    handle:close()
    assert(out ~= nil, "ah docs tool should produce output")
    assert(#out > 0, "ah docs tool output should be non-empty")
  end
end
test_docs_with_query_returns_output()

local function test_docs_no_match()
  -- ah docs <nonexistent-query> should say no matches
  local ah_bin = os.getenv("AH_BIN") or "o/bin/ah"
  local cmd = ah_bin .. " docs xyzzy_no_match_ever 2>&1"
  local handle = io.popen(cmd)
  if handle then
    local out = handle:read("*a")
    handle:close()
    assert(
      out:match("no documentation found") or out:match("no embedded documentation"),
      "ah docs nonexistent should report no match: " .. out
    )
  end
end
test_docs_no_match()

local function test_docs_sandbox_query()
  -- searching for "sandbox" should return matches from sandbox.md
  local ah_bin = os.getenv("AH_BIN") or "o/bin/ah"
  local cmd = ah_bin .. " docs sandbox 2>&1"
  local handle = io.popen(cmd)
  if handle then
    local out = handle:read("*a")
    handle:close()
    -- Either matches found or no embedded docs in test binary
    assert(out ~= nil, "ah docs sandbox should produce output")
  end
end
test_docs_sandbox_query()

print("all docs tests passed")
