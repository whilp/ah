#!/usr/bin/env cosmic
-- test_tools.tl: tests for agent tools
local cosmo = require("cosmo")
local path = require("cosmo.path")
local unix = require("cosmo.unix")
local tools = require("ah.tools")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_read_tool()
  local result, is_error = tools.execute_tool("read", {path = "/etc/hostname"})
  assert(not is_error, "read should succeed: " .. result)
  assert(result:match("1\t"), "should have line numbers")
  print("✓ read tool works")
end

local function test_read_nonexistent()
  local result, is_error = tools.execute_tool("read", {path = "/nonexistent/file"})
  assert(is_error, "should fail for nonexistent file")
  assert(result:match("error"), "should return error message")
  print("✓ read tool handles missing files")
end

local function test_write_tool()
  local test_file = os.getenv("TEST_TMPDIR") .. "/test_write.txt"
  local result, is_error = tools.execute_tool("write", {path = test_file, content = "hello world"})
  assert(not is_error, "write should succeed: " .. result)
  assert(result:match("wrote.*bytes"), "should report bytes written")
  print("✓ write tool works")
end

local function test_edit_tool()
  local test_file = os.getenv("TEST_TMPDIR") .. "/test_edit.txt"
  tools.execute_tool("write", {path = test_file, content = "hello world"})
  local result, is_error = tools.execute_tool("edit", {
    path = test_file,
    old_string = "hello",
    new_string = "goodbye"
  })
  assert(not is_error, "edit should succeed: " .. result)
  
  local content, _ = tools.execute_tool("read", {path = test_file})
  assert(content:match("goodbye world"), "content should be changed")
  print("✓ edit tool works")
end

local function test_bash_tool()
  local result, is_error = tools.execute_tool("bash", {command = "echo hello"})
  assert(not is_error, "bash should succeed")
  assert(result:match("hello"), "should capture stdout")
  print("✓ bash tool works")
end

local function test_bash_exit_code()
  local result, is_error = tools.execute_tool("bash", {command = "exit 1"})
  assert(is_error, "should report error for non-zero exit")
  assert(result:match("exit code: 1"), "should report exit code")
  print("✓ bash tool handles exit codes")
end

local function test_tool_definitions()
  local defs = tools.get_tool_definitions()
  assert(#defs == 4, "should have 4 tools")

  for _, d in ipairs(defs) do
    local def = d as {string:any}
    assert(def.name, "tool should have name")
    assert(def.description, "tool should have description")
    assert(def.input_schema, "tool should have input_schema")
    local schema = def.input_schema as {string:any}
    assert(schema.type == "object", "schema type should be object")
    assert(schema.properties, "schema should have properties")
    assert(schema.required, "schema should have required array")
  end

  -- Check read tool specifically
  local read_def = defs[1] as {string:any}
  assert(read_def.name == "read", "first tool should be read")
  local read_schema = read_def.input_schema as {string:any}
  local read_props = read_schema.properties as {string:any}
  local read_required = read_schema.required as {string}
  assert(read_props.path, "read should have path property")
  assert(read_required[1] == "path", "path should be required")

  print("✓ tool definitions are correct")
end

test_tool_definitions()
test_read_tool()
test_read_nonexistent()
test_write_tool()
test_edit_tool()
test_bash_tool()
test_bash_exit_code()

-- Custom tool tests
local function test_is_valid_tool()
  assert(not tools.is_valid_tool(nil), "nil should be invalid")
  assert(not tools.is_valid_tool("string"), "string should be invalid")
  assert(not tools.is_valid_tool({}), "empty table should be invalid")
  assert(not tools.is_valid_tool({name = "foo"}), "missing fields should be invalid")

  local valid = {
    name = "test",
    description = "A test tool",
    input_schema = {type = "object", properties = {}, required = {}},
    execute = function() return "ok", false end,
  }
  assert(tools.is_valid_tool(valid), "valid tool should pass validation")
  print("✓ is_valid_tool works")
end
test_is_valid_tool()

local function test_load_custom_tools_empty_dir()
  local empty_dir = path.join(TEST_TMPDIR, "empty_tools")
  unix.makedirs(empty_dir)

  local loaded = tools.load_custom_tools_from_dir(empty_dir)
  assert(#loaded == 0, "should load 0 tools from empty dir")
  print("✓ load_custom_tools handles empty directory")
end
test_load_custom_tools_empty_dir()

local function test_load_custom_tools_nonexistent()
  local loaded = tools.load_custom_tools_from_dir("/nonexistent/dir")
  assert(#loaded == 0, "should return empty for nonexistent dir")
  print("✓ load_custom_tools handles nonexistent directory")
end
test_load_custom_tools_nonexistent()

local function test_load_custom_tool()
  local tool_dir = path.join(TEST_TMPDIR, "custom_tools")
  unix.makedirs(tool_dir)

  cosmo.Barf(path.join(tool_dir, "hello.lua"), [[
return {
  name = "hello",
  description = "Say hello",
  input_schema = {type = "object", properties = {name = {type = "string"}}, required = {}},
  execute = function(input)
    local name = input.name or "world"
    return "hello, " .. name .. "!", false
  end,
}
]])

  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 1, "should load 1 tool")
  assert(loaded[1].name == "hello", "tool name should be hello")

  local result, is_error = loaded[1].execute({name = "test"})
  assert(result == "hello, test!", "execute should work: " .. result)
  assert(not is_error, "should not be error")
  print("✓ load_custom_tools loads valid tool")
end
test_load_custom_tool()

local function test_invalid_tool_skipped()
  local tool_dir = path.join(TEST_TMPDIR, "invalid_tools")
  unix.makedirs(tool_dir)

  cosmo.Barf(path.join(tool_dir, "bad.lua"), "return nil")
  cosmo.Barf(path.join(tool_dir, "also_bad.lua"), "return {}")
  cosmo.Barf(path.join(tool_dir, "good.lua"), [[
return {
  name = "good",
  description = "Good tool",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "ok", false end,
}
]])

  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 1, "should only load valid tool")
  assert(loaded[1].name == "good", "should load good tool")
  print("✓ invalid tools are skipped")
end
test_invalid_tool_skipped()

local function test_custom_tool_override()
  local global_dir = path.join(TEST_TMPDIR, "global_tools")
  local project_dir = path.join(TEST_TMPDIR, "project_tools")
  unix.makedirs(global_dir)
  unix.makedirs(project_dir)

  cosmo.Barf(path.join(global_dir, "foo.lua"), [[
return {
  name = "foo",
  description = "global foo",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "global", false end,
}
]])

  cosmo.Barf(path.join(project_dir, "foo.lua"), [[
return {
  name = "foo",
  description = "project foo",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "project", false end,
}
]])

  local all = tools.load_custom_tools(global_dir, project_dir)
  local foo = nil
  for _, t in ipairs(all) do
    if t.name == "foo" then foo = t end
  end
  assert(foo, "should have foo tool")
  assert(foo.description == "project foo", "project should override global")
  print("✓ project tools override global tools")
end
test_custom_tool_override()

print("\nAll tools tests passed!")
