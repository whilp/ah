#!/usr/bin/env cosmic
-- test_toolload.tl: tests for tool loading infrastructure (AST guard, file loading, dir scanning)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local tools = require("ah.tools")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

-- is_valid_tool tests

local function test_is_valid_tool()
  assert(not tools.is_valid_tool(nil), "nil should be invalid")
  assert(not tools.is_valid_tool("string"), "string should be invalid")
  assert(not tools.is_valid_tool({}), "empty table should be invalid")
  assert(not tools.is_valid_tool({name = "foo"}), "missing fields should be invalid")

  local valid = {
    name = "test",
    description = "A test tool",
    input_schema = {type = "object", properties = {}, required = {}},
    execute = function(_: {string: any}): string, boolean return "ok", false end,
  }
  assert(tools.is_valid_tool(valid), "valid tool should pass validation")
  print("✓ is_valid_tool works")
end
test_is_valid_tool()

-- load_custom_tools_from_dir tests

local function test_load_custom_tools_empty_dir()
  local empty_dir = fs.join(TEST_TMPDIR, "empty_tools")
  fs.makedirs(empty_dir)
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
  local tool_dir = fs.join(TEST_TMPDIR, "custom_tools_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "hello.lua"), [[
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
  local tool_dir = fs.join(TEST_TMPDIR, "invalid_tools_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "bad.lua"), "return nil")
  cio.barf(fs.join(tool_dir, "also_bad.lua"), "return {}")
  cio.barf(fs.join(tool_dir, "good.lua"), [[
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

-- Teal tool loading

local function test_teal_tool_loading()
  local project = fs.join(TEST_TMPDIR, "teal_tool_load")
  local project_tools = fs.join(project, "tools")
  fs.makedirs(project_tools)
  cio.barf(fs.join(project_tools, "greet.tl"), [[
return {
  name = "greet",
  description = "Greet in teal",
  system_prompt = "Always greet warmly.",
  input_schema = {type = "object", properties = {name = {type = "string"}}, required = {"name"}},
  execute = function(input: {string:any}): string, boolean, any
    local who = (input.name as string) or "world"
    return "hello, " .. who, false
  end,
}
]])

  tools.init_custom_tools(project)
  local result, is_error = tools.execute_tool("greet", {name = "teal"})
  assert(not is_error, "teal tool should execute")
  assert(result == "hello, teal", "should run teal tool: " .. result)
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ .tl tools loaded from cwd/tools/")
end
test_teal_tool_loading()

local function test_teal_overrides_lua()
  local project = fs.join(TEST_TMPDIR, "tl_over_lua_load")
  local project_tools = fs.join(project, "tools")
  fs.makedirs(project_tools)

  cio.barf(fs.join(project_tools, "dup.lua"), [[
return {
  name = "dup", description = "lua version",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "from-lua", false end,
}
]])
  cio.barf(fs.join(project_tools, "dup.tl"), [[
return {
  name = "dup", description = "teal version",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function(): string, boolean return "from-teal", false end,
}
]])

  tools.init_custom_tools(project)
  local result, is_error = tools.execute_tool("dup", {})
  assert(not is_error, "should execute")
  assert(result == "from-teal", ".tl should override .lua: " .. result)
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ .tl overrides .lua with same basename")
end
test_teal_overrides_lua()

-- Require tests

local function test_lua_tool_require_lua()
  local tool_dir = fs.join(TEST_TMPDIR, "lua_require_lua_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "helper_load.lua"), [[
return { greet = function(name) return "hello, " .. name end }
]])
  cio.barf(fs.join(tool_dir, "greeter_load.lua"), [[
local helper_load = require("helper_load")
return {
  name = "greeter_load",
  description = "Greet with helper",
  input_schema = {type = "object", properties = {name = {type = "string"}}, required = {"name"}},
  execute = function(input) return helper_load.greet(input.name), false end,
}
]])

  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 1, "should load 1 tool: " .. tostring(#loaded))
  assert(loaded[1].name == "greeter_load", "should load greeter tool")
  local result, is_error = loaded[1].execute({name = "world"})
  assert(not is_error, "greeter should succeed")
  assert(result == "hello, world", "should use helper module: " .. result)
  package.loaded["helper_load"] = nil
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ lua tool can require sibling lua module")
end
test_lua_tool_require_lua()

local function test_teal_tool_require_teal()
  local tool_dir = fs.join(TEST_TMPDIR, "tl_require_tl_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "tl_helper_load.tl"), [[
local record M
  greet: function(string): string
end
function M.greet(name: string): string
  return "hi, " .. name
end
return M
]])
  cio.barf(fs.join(tool_dir, "tl_greeter_load.tl"), [[
local helper = require("tl_helper_load")
return {
  name = "tl_greeter_load",
  description = "Greet with teal helper",
  input_schema = {type = "object", properties = {name = {type = "string"}}, required = {"name"}},
  execute = function(input: {string:any}): string, boolean
    local who = input.name as string
    return helper.greet(who), false
  end,
}
]])

  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  local greeter: {string: any} = nil
  for _, t in ipairs(loaded) do
    if t.name == "tl_greeter_load" then greeter = t as {string: any} end
  end
  assert(greeter, "should load tl_greeter_load tool")
  local exec = greeter.execute as function(input: {string: any}): string, boolean
  local result, is_error = exec({name = "teal"})
  assert(not is_error, "tl_greeter should succeed")
  assert(result == "hi, teal", "should use teal helper module: " .. result)
  package.loaded["tl_helper_load"] = nil
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ teal tool can require sibling teal module")
end
test_teal_tool_require_teal()

-- looks_like_tool AST guard tests

local function test_looks_like_tool_valid_lua()
  local source = [[
return {
  name = "foo", description = "A test tool",
  input_schema = {type = "object", properties = {}},
  execute = function() return "ok", false end,
}
]]
  assert(tools.looks_like_tool(source, true), "valid lua tool should pass")
  print("✓ looks_like_tool accepts valid lua tool")
end
test_looks_like_tool_valid_lua()

local function test_looks_like_tool_valid_teal()
  local source = [[
return {
  name = "greet", description = "test",
  input_schema = {type = "object", properties = {}},
  execute = function(input: {string:any}): string, boolean return "ok", false end,
}
]]
  assert(tools.looks_like_tool(source, false), "valid teal tool should pass")
  print("✓ looks_like_tool accepts valid teal tool")
end
test_looks_like_tool_valid_teal()

local function test_looks_like_tool_os_exit()
  assert(not tools.looks_like_tool("os.exit(0)", true), "os.exit() script should be rejected")
  print("✓ looks_like_tool rejects os.exit() script")
end
test_looks_like_tool_os_exit()

local function test_looks_like_tool_no_return()
  assert(not tools.looks_like_tool("print('hello')", true), "script without return should be rejected")
  print("✓ looks_like_tool rejects script without return")
end
test_looks_like_tool_no_return()

local function test_looks_like_tool_empty()
  assert(not tools.looks_like_tool("", true), "empty source should be rejected")
  print("✓ looks_like_tool rejects empty source")
end
test_looks_like_tool_empty()

local function test_looks_like_tool_syntax_error()
  assert(not tools.looks_like_tool("invalid !!!", true), "syntax error should be rejected")
  print("✓ looks_like_tool rejects syntax errors")
end
test_looks_like_tool_syntax_error()

local function test_looks_like_tool_missing_name()
  local source = 'return { description = "no name", execute = function() end }'
  assert(not tools.looks_like_tool(source, true), "table missing name should be rejected")
  print("✓ looks_like_tool rejects table missing name key")
end
test_looks_like_tool_missing_name()

local function test_looks_like_tool_missing_execute()
  local source = 'return { name = "foo", description = "no execute" }'
  assert(not tools.looks_like_tool(source, true), "table missing execute should be rejected")
  print("✓ looks_like_tool rejects table missing execute key")
end
test_looks_like_tool_missing_execute()

local function test_looks_like_tool_variable_return()
  assert(tools.looks_like_tool("local t = {} ; t.name = 'foo' ; return t", true), "variable return should pass optimistically")
  print("✓ looks_like_tool accepts variable return optimistically")
end
test_looks_like_tool_variable_return()

local function test_looks_like_tool_function_call_return()
  assert(tools.looks_like_tool("return require('foo').make_tool()", true), "function call return should pass optimistically")
  print("✓ looks_like_tool accepts function call return optimistically")
end
test_looks_like_tool_function_call_return()

local function test_looks_like_tool_return_nil()
  assert(tools.looks_like_tool("return nil", true), "return nil should pass optimistically")
  print("✓ looks_like_tool accepts return nil optimistically")
end
test_looks_like_tool_return_nil()

-- Integration: os.exit() guard

local function test_os_exit_in_tools_dir_skipped()
  local tool_dir = fs.join(TEST_TMPDIR, "os_exit_tools_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "killer.lua"), "os.exit(1)")
  cio.barf(fs.join(tool_dir, "safe.lua"), [[
return {
  name = "safe", description = "Safe tool",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "safe", false end,
}
]])

  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 1, "should load only the safe tool")
  assert(loaded[1].name == "safe", "should load safe tool")
  print("✓ os.exit() script in tools dir is skipped")
end
test_os_exit_in_tools_dir_skipped()

local function test_os_exit_teal_skipped()
  local tool_dir = fs.join(TEST_TMPDIR, "os_exit_teal_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "killer.tl"), "os.exit(1)")
  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 0, "os.exit teal file should be skipped")
  print("✓ os.exit() in .tl file is skipped")
end
test_os_exit_teal_skipped()

local function test_override_os_exit_guarded()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local defs_before = #tools.get_tool_definitions()
  local tool_dir = fs.join(TEST_TMPDIR, "override_os_exit_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "bad.lua"), "os.exit(1)")
  tools.add_tool_override("bad", fs.join(tool_dir, "bad.lua"))
  assert(defs_before == #tools.get_tool_definitions(), "os.exit override should not be added")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ add_tool_override guards against os.exit()")
end
test_override_os_exit_guarded()

-- Graceful error handling

local function test_teal_syntax_error_skipped()
  local tool_dir = fs.join(TEST_TMPDIR, "teal_syntax_error_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "broken.tl"), "invalid syntax !!!")
  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 0, "broken .tl should be skipped")
  print("✓ .tl file with syntax error is skipped")
end
test_teal_syntax_error_skipped()

local function test_lua_load_error_skipped()
  local tool_dir = fs.join(TEST_TMPDIR, "lua_load_error_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "broken.lua"), "this is not lua !!!")
  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 0, "broken .lua should be skipped")
  print("✓ .lua file with load error is skipped")
end
test_lua_load_error_skipped()

local function test_teal_runtime_error_at_load_skipped()
  local tool_dir = fs.join(TEST_TMPDIR, "teal_runtime_error_load")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "throws.tl"), '-- valid teal\nerror("boom at load time")')
  local loaded = tools.load_custom_tools_from_dir(tool_dir)
  assert(#loaded == 0, ".tl that throws at load should be skipped")
  print("✓ .tl file that throws at module level is skipped")
end
test_teal_runtime_error_at_load_skipped()

local function test_add_tool_override_teal_syntax_error()
  local tool_dir = fs.join(TEST_TMPDIR, "override_teal_syntax_error_load")
  fs.makedirs(tool_dir)
  local broken_path = fs.join(tool_dir, "broken.tl")
  cio.barf(broken_path, "invalid syntax !!!")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local defs_before = #tools.get_tool_definitions()
  tools.add_tool_override("broken", broken_path)
  assert(defs_before == #tools.get_tool_definitions(), "broken .tl should not add a tool")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ add_tool_override skips .tl with syntax error")
end
test_add_tool_override_teal_syntax_error()

print("\nAll toolload tests passed!")
