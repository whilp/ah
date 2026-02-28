#!/usr/bin/env cosmic
-- test_pptx_tool.tl: tests for the pptx sys tool record structure and input validation

local tools = require("ah.tools")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"
local _ = TEST_TMPDIR  -- suppress unused warning

-- Reload tools from cwd so we get built-in sys tools (including pptx)
local cwd = fs.getcwd()
tools.init_custom_tools(cwd)

-- Helper: get the pptx tool definition (API schema)
local function get_pptx_def(): {string: any}
  local defs = tools.get_tool_definitions()
  for _, d in ipairs(defs) do
    local def = d as {string: any}
    if def.name == "pptx" then
      return def
    end
  end
  return nil
end

-- test: pptx tool is registered
local function test_pptx_tool_registered()
  local def = get_pptx_def()
  assert(def ~= nil, "pptx tool should be registered")
  print("✓ pptx tool is registered")
end
test_pptx_tool_registered()

-- test: tool definition has required API schema fields
local function test_pptx_tool_record_fields()
  local def = get_pptx_def()
  assert(def ~= nil, "pptx tool should exist")
  assert(type(def.name) == "string", "name should be a string")
  assert(def.name == "pptx", "name should be 'pptx'")
  assert(type(def.description) == "string", "description should be a string")
  assert(def.description ~= "", "description should not be empty")
  assert(type(def.input_schema) == "table", "input_schema should be a table")
  print("✓ pptx tool definition has required fields")
end
test_pptx_tool_record_fields()

-- test: input_schema has required 'path' field
local function test_pptx_input_schema()
  local def = get_pptx_def()
  assert(def ~= nil, "pptx tool should exist")
  local schema = def.input_schema as {string: any}
  assert(schema.type == "object", "schema type should be object")
  local props = schema.properties as {string: any}
  assert(props ~= nil, "schema should have properties")
  assert(props.path ~= nil, "schema should have 'path' property")
  local required = schema.required as {string}
  assert(required ~= nil, "schema should have required list")
  local has_path = false
  for _, r in ipairs(required) do
    if r == "path" then
      has_path = true
    end
  end
  assert(has_path, "path should be in required list")
  print("✓ pptx input_schema has required 'path' field")
end
test_pptx_input_schema()

-- test: missing path returns validation error
local function test_pptx_missing_path()
  local result, is_error = tools.execute_tool("pptx", {})
  assert(is_error, "missing path should return error")
  assert(result:match("missing required") or result:match("error"), "should report error")
  print("✓ pptx returns error for missing path")
end
test_pptx_missing_path()

-- test: non-.pptx extension returns error
local function test_pptx_wrong_extension()
  local result, is_error = tools.execute_tool("pptx", {path = "/tmp/test.docx"})
  assert(is_error, "wrong extension should return error")
  assert(result:match("error") or result:match("pptx"), "should report extension error")
  print("✓ pptx returns error for non-.pptx extension")
end
test_pptx_wrong_extension()

-- test: nonexistent file returns error
local function test_pptx_nonexistent_file()
  local result, is_error = tools.execute_tool("pptx", {path = "/nonexistent/path/test.pptx"})
  assert(is_error, "nonexistent file should return error")
  assert(result:match("error"), "should report error")
  print("✓ pptx returns error for nonexistent file")
end
test_pptx_nonexistent_file()

print("\nAll pptx tool tests passed!")
