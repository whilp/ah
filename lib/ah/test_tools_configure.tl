#!/usr/bin/env cosmic
-- test_tools_configure.tl: tests for tools.configure() declarative tool sets
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local tools = require("ah.tools")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_configure_deny()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local before = #tools.get_tool_definitions()
  assert(before >= 4, "should have builtins before configure")
  tools.configure({deny = {"bash"}})
  local _, is_error = tools.execute_tool("bash", {command = "echo hi"})
  assert(is_error, "bash should be removed after configure deny")
  local defs = tools.get_tool_definitions()
  local by_name: {string: boolean} = {}
  for _, d in ipairs(defs) do by_name[(d as {string: any}).name as string] = true end
  assert(not by_name["bash"], "bash should not be in tool list")
  assert(by_name["read"], "read should still be present")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ configure({deny=...}) removes named tools")
end
test_configure_deny()

local function test_configure_allow()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  tools.configure({allow = {"read", "write"}})
  local defs = tools.get_tool_definitions()
  assert(#defs == 2, "should have exactly 2 tools: " .. tostring(#defs))
  local by_name: {string: boolean} = {}
  for _, d in ipairs(defs) do by_name[(d as {string: any}).name as string] = true end
  assert(by_name["read"], "read should be present")
  assert(by_name["write"], "write should be present")
  assert(not by_name["bash"], "bash should not be present")
  assert(not by_name["edit"], "edit should not be present")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ configure({allow=...}) keeps only named tools")
end
test_configure_allow()

local function test_configure_only_by_name()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  tools.configure({only = {"read"}})
  local defs = tools.get_tool_definitions()
  assert(#defs == 1, "should have exactly 1 tool: " .. tostring(#defs))
  assert((defs[1] as {string: any}).name == "read", "should be read")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ configure({only=...}) rebuilds set with only named tools")
end
test_configure_only_by_name()

local function test_configure_only_unknown_skipped()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  tools.configure({only = {"read", "nonexistent_tool_xyz"}})
  local defs = tools.get_tool_definitions()
  assert(#defs == 1, "unknown entry should be silently skipped: " .. tostring(#defs))
  assert((defs[1] as {string: any}).name == "read", "should only have read")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ configure({only=...}) skips unknown names silently")
end
test_configure_only_unknown_skipped()

local function test_configure_allow_then_deny()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  tools.configure({allow = {"read", "write", "bash"}, deny = {"bash"}})
  local defs = tools.get_tool_definitions()
  local by_name: {string: boolean} = {}
  for _, d in ipairs(defs) do by_name[(d as {string: any}).name as string] = true end
  assert(by_name["read"], "read should be present")
  assert(by_name["write"], "write should be present")
  assert(not by_name["bash"], "bash should have been denied")
  assert(#defs == 2, "should have 2 tools: " .. tostring(#defs))
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ configure({allow=..., deny=...}) applies allow then deny")
end
test_configure_allow_then_deny()

local function test_configure_only_file_path()
  local tool_dir = fs.join(TEST_TMPDIR, "configure_file_tool")
  fs.makedirs(tool_dir)
  local tool_path = fs.join(tool_dir, "mytool.lua")
  cio.barf(tool_path, [[
return {
  name = "mytool", description = "A file-based tool",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "from-file", false end,
}
]])
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  tools.configure({only = {"read", tool_path}})
  local defs = tools.get_tool_definitions()
  local by_name: {string: boolean} = {}
  for _, d in ipairs(defs) do by_name[(d as {string: any}).name as string] = true end
  assert(by_name["read"], "read should be present")
  assert(by_name["mytool"], "file-path tool should be loaded")
  assert(#defs == 2, "should have 2 tools: " .. tostring(#defs))
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ configure({only=...}) loads file-path entries")
end
test_configure_only_file_path()

print("\nAll tools configure tests passed!")
