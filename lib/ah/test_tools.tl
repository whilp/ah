#!/usr/bin/env cosmic
-- test_tools.tl: tests for agent tools
local tools = require("ah.tools")

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

print("\nAll tools tests passed!")
