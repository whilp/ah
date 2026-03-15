#!/usr/bin/env cosmic
-- test_result.tl: tests for the result tool (reading truncated output from DB)
local db = require("ah.db")
local tools = require("ah.tools")
local time = require("cosmic.time")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"
local test_db_path = TEST_TMPDIR .. "/test_result_" .. tostring((time.now())) .. ".db"

local function setup(): db.DB
  local d, err = db.open(test_db_path)
  assert(d, "failed to open db: " .. (err or ""))
  tools.init_custom_tools()
  return d
end

local function teardown(d: db.DB)
  db.close(d)
  fs.unlink(test_db_path)
  fs.unlink(test_db_path .. "-wal")
  fs.unlink(test_db_path .. "-shm")
end

-- Helper: create a tool_result content block with given tool_id and output
local function add_tool_result(d: db.DB, tool_id: string, output: string)
  db.begin_transaction(d)
  local msg = db.create_message(d, "user", nil)
  local opts: db.ContentBlockOpts = {
    tool_id = tool_id,
    tool_output = output,
  }
  db.add_content_block(d, msg.id, "tool_result", opts)
  db.commit(d)
end

local function test_result_basic()
  local d = setup()
  add_tool_result(d, "toolu_abc123", "hello world\nline two\nline three")

  local ctx: tools.ToolContext = {db = d}
  local output, is_error = tools.execute_tool("result", {tool_use_id = "toolu_abc123"}, ctx)
  assert(not is_error, "should not error: " .. (output or ""))
  assert(output == "hello world\nline two\nline three", "should return full output: " .. output)
  print("✓ result tool returns full output")
  teardown(d)
end
test_result_basic()

local function test_result_with_offset_limit()
  local d = setup()
  local lines = {}
  for i = 1, 50 do
    table.insert(lines, "line " .. tostring(i))
  end
  add_tool_result(d, "toolu_offset1", table.concat(lines, "\n"))

  local ctx: tools.ToolContext = {db = d}
  local output, is_error = tools.execute_tool("result", {tool_use_id = "toolu_offset1", offset = 10, limit = 5}, ctx)
  assert(not is_error, "should not error: " .. (output or ""))
  assert(output:match("%[lines 10%-14 of 50%]"), "should have line range header: " .. output)
  assert(output:match("10\tline 10"), "should include line 10: " .. output)
  assert(output:match("14\tline 14"), "should include line 14: " .. output)
  assert(not output:match("15\tline 15"), "should not include line 15")
  print("✓ result tool supports offset/limit")
  teardown(d)
end
test_result_with_offset_limit()

local function test_result_missing_tool_use_id()
  local d = setup()
  local ctx: tools.ToolContext = {db = d}
  local output, is_error = tools.execute_tool("result", {tool_use_id = "toolu_nonexistent"}, ctx)
  assert(is_error, "should error for missing tool_use_id")
  assert(output:match("no tool result found"), "should say not found: " .. output)
  print("✓ result tool errors on missing tool_use_id")
  teardown(d)
end
test_result_missing_tool_use_id()

local function test_result_empty_tool_use_id()
  local d = setup()
  local ctx: tools.ToolContext = {db = d}
  local output, is_error = tools.execute_tool("result", {tool_use_id = ""}, ctx)
  assert(is_error, "should error for empty tool_use_id")
  print("✓ result tool errors on empty tool_use_id")
  teardown(d)
end
test_result_empty_tool_use_id()

local function test_result_offset_beyond_end()
  local d = setup()
  add_tool_result(d, "toolu_short1", "one\ntwo\nthree")

  local ctx: tools.ToolContext = {db = d}
  local output, is_error = tools.execute_tool("result", {tool_use_id = "toolu_short1", offset = 100, limit = 5}, ctx)
  assert(not is_error, "should not error")
  assert(output:match("%[lines 100%-"), "should have header")
  print("✓ result tool handles offset beyond end")
  teardown(d)
end
test_result_offset_beyond_end()

local function test_result_no_offset_no_limit()
  local d = setup()
  add_tool_result(d, "toolu_full1", "full output here")

  local ctx: tools.ToolContext = {db = d}
  local output, is_error = tools.execute_tool("result", {tool_use_id = "toolu_full1"}, ctx)
  assert(not is_error, "should not error")
  assert(output == "full output here", "should return raw output without header: " .. output)
  print("✓ result tool returns raw output without offset/limit")
  teardown(d)
end
test_result_no_offset_no_limit()

print("\nAll result tests passed!")
