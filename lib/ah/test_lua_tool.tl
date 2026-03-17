#!/usr/bin/env cosmic
-- test_lua_tool.tl: tests for the lua sandboxed execution tool
local tools = require("ah.tools")
local cenv = require("cosmic.env")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"
tools.init_custom_tools(TEST_TMPDIR .. "/nonexistent")

-- Load the lua tool directly for unit testing
local lua_tool = require("sys.tools.lua")

-- Tool record structure tests

local function test_tool_structure()
  assert(type(lua_tool) == "table", "lua tool should be a table")
  assert(lua_tool.name == "lua", "name should be 'lua'")
  assert(type(lua_tool.description) == "string", "description should be a string")
  assert(lua_tool.description ~= "", "description should not be empty")
  assert(type(lua_tool.input_schema) == "table", "input_schema should be a table")
  assert(type(lua_tool.execute) == "function", "execute should be a function")
  local schema = lua_tool.input_schema as {string: any}
  assert(schema.type == "object", "schema type should be object")
  local props = schema.properties as {string: any}
  assert(props, "schema should have properties")
  assert(props["code"], "schema should have code property")
  local required = schema.required as {string}
  assert(required, "schema should have required")
  local has_code = false
  for _, v in ipairs(required) do
    if v == "code" then has_code = true end
  end
  assert(has_code, "code should be required")
  print("✓ lua tool structure is valid")
end
test_tool_structure()

-- Input validation

local function test_missing_code()
  local result, is_error = lua_tool.execute({})
  assert(is_error, "missing code should return error")
  assert(result:match("code is required"), "should mention code: " .. result)
  print("✓ missing code returns error")
end
test_missing_code()

local function test_empty_code()
  local result, is_error = lua_tool.execute({code = ""})
  assert(is_error, "empty code should return error")
  assert(result:match("code is required"), "should mention code: " .. result)
  print("✓ empty code returns error")
end
test_empty_code()

-- Safe execution

local function test_safe_math()
  local result, is_error = lua_tool.execute({code = "return 1 + 1"})
  assert(not is_error, "math should succeed: " .. result)
  assert(result:match("2"), "should return 2: " .. result)
  print("✓ safe math executes correctly")
end
test_safe_math()

local function test_print_capture()
  local result, is_error = lua_tool.execute({code = 'print("hello world")'})
  assert(not is_error, "print should succeed: " .. result)
  assert(result:match("hello world"), "should capture print output: " .. result)
  print("✓ print output captured")
end
test_print_capture()

local function test_return_value()
  local result, is_error = lua_tool.execute({code = "return 42"})
  assert(not is_error, "return should succeed: " .. result)
  assert(result:match("42"), "should return 42: " .. result)
  print("✓ return values captured")
end
test_return_value()

local function test_multiple_return_values()
  local result, is_error = lua_tool.execute({code = "return 1, 2, 3"})
  assert(not is_error, "multiple returns should succeed: " .. result)
  assert(result:match("1"), "should have 1")
  assert(result:match("2"), "should have 2")
  assert(result:match("3"), "should have 3")
  print("✓ multiple return values captured")
end
test_multiple_return_values()

local function test_math_library()
  local result, is_error = lua_tool.execute({code = "return math.sqrt(16)"})
  assert(not is_error, "math.sqrt should succeed: " .. result)
  assert(result:match("4"), "should return 4: " .. result)
  print("✓ math library available")
end
test_math_library()

local function test_string_library()
  local result, is_error = lua_tool.execute({code = 'return string.upper("hello")'})
  assert(not is_error, "string.upper should succeed: " .. result)
  assert(result:match("HELLO"), "should return HELLO: " .. result)
  print("✓ string library available")
end
test_string_library()

local function test_table_library()
  local result, is_error = lua_tool.execute({code = "local t = {3,1,2}; table.sort(t); return t[1], t[2], t[3]"})
  assert(not is_error, "table.sort should succeed: " .. result)
  assert(result:match("1"), "sorted table should start with 1: " .. result)
  print("✓ table library available")
end
test_table_library()

local function test_print_and_return()
  local result, is_error = lua_tool.execute({code = 'print("output"); return "done"'})
  assert(not is_error, "print + return should succeed: " .. result)
  assert(result:match("output"), "should have print output: " .. result)
  assert(result:match("done"), "should have return value: " .. result)
  print("✓ print and return value both captured")
end
test_print_and_return()

local function test_no_output()
  local result, is_error = lua_tool.execute({code = "local x = 1 + 1"})
  assert(not is_error, "no output code should succeed: " .. result)
  assert(result:match("no output"), "should indicate no output: " .. result)
  print("✓ no output handled correctly")
end
test_no_output()

-- Blocked unsafe functions

local function test_blocked_os()
  local _, is_error = lua_tool.execute({code = 'os.execute("id")'})
  assert(is_error, "os.execute should be blocked")
  print("✓ os is blocked")
end
test_blocked_os()

local function test_blocked_io()
  local _, is_error = lua_tool.execute({code = 'io.open("/etc/passwd")'})
  assert(is_error, "io.open should be blocked")
  print("✓ io is blocked")
end
test_blocked_io()

local function test_blocked_require()
  local _, is_error = lua_tool.execute({code = 'require("os")'})
  assert(is_error, "require should be blocked")
  print("✓ require is blocked")
end
test_blocked_require()

local function test_blocked_load()
  local _, is_error = lua_tool.execute({code = 'load("return 1")()'})
  assert(is_error, "load should be blocked")
  print("✓ load is blocked")
end
test_blocked_load()

local function test_blocked_loadfile()
  local _, is_error = lua_tool.execute({code = 'loadfile("/etc/passwd")'})
  assert(is_error, "loadfile should be blocked")
  print("✓ loadfile is blocked")
end
test_blocked_loadfile()

local function test_blocked_dofile()
  local _, is_error = lua_tool.execute({code = 'dofile("/etc/passwd")'})
  assert(is_error, "dofile should be blocked")
  print("✓ dofile is blocked")
end
test_blocked_dofile()

local function test_blocked_string_dump()
  local _, is_error = lua_tool.execute({code = 'return string.dump(function() end)'})
  assert(is_error, "string.dump should be blocked")
  print("✓ string.dump is blocked")
end
test_blocked_string_dump()

-- Error handling

local function test_syntax_error()
  local result, is_error = lua_tool.execute({code = "this is not valid lua !!!"})
  assert(is_error, "syntax error should return is_error=true")
  assert(result:match("error"), "should describe the error: " .. result)
  print("✓ syntax error handled correctly")
end
test_syntax_error()

local function test_runtime_error()
  local result, is_error = lua_tool.execute({code = 'error("boom")'})
  assert(is_error, "runtime error should return is_error=true")
  assert(result:match("boom"), "should include error message: " .. result)
  print("✓ runtime error handled correctly")
end
test_runtime_error()

local function test_nil_index_error()
  local _, is_error = lua_tool.execute({code = "local x = nil; return x.foo"})
  assert(is_error, "nil index should return error")
  print("✓ nil index error handled correctly")
end
test_nil_index_error()

-- Instruction limit (infinite loop protection)

local function test_instruction_limit()
  local result, is_error = lua_tool.execute({
      code = "while true do end",
      instruction_limit = 10000,
    })
  assert(is_error, "infinite loop should be stopped by instruction limit")
  assert(result:match("instruction limit"), "should mention instruction limit: " .. result)
  print("✓ instruction limit stops infinite loops")
end
test_instruction_limit()

local function test_default_instruction_limit()
  -- Verify very long loops are still stopped by the default limit
  local result, is_error = lua_tool.execute({
      code = "local i = 0; while i < 1e18 do i = i + 1 end; return i",
    })
  assert(is_error, "very long loop should hit default limit")
  assert(result:match("instruction limit"), "should mention instruction limit: " .. result)
  print("✓ default instruction limit stops very long loops")
end
test_default_instruction_limit()

-- Details return value

local function test_details_returned()
  local _, _, details = lua_tool.execute({code = "return 1"})
  assert(details ~= nil, "details should be returned")
  local d = details as {string: any}
  assert(d.instruction_count ~= nil, "details should have instruction_count")
  assert((d.instruction_count as integer) >= 0, "instruction_count should be non-negative")
  print("✓ details with instruction_count returned")
end
test_details_returned()

print("\nAll lua tool tests passed!")
