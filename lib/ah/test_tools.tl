#!/usr/bin/env cosmic
-- test_tools.tl: tests for tool execution, validation, and overrides
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local tools = require("ah.tools")
local json = require("cosmic.json")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

-- Core tool tests

local function test_tool_definitions()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local defs = tools.get_tool_definitions()
  assert(#defs >= 4, "should have at least 4 tools: " .. tostring(#defs))
  local by_name: {string: {string: any}} = {}
  for _, d in ipairs(defs) do
    local def = d as {string: any}
    assert(def.name, "tool should have name")
    assert(def.description, "tool should have description")
    assert(def.input_schema, "tool should have input_schema")
    by_name[def.name as string] = def
  end
  assert(by_name["read"], "should have read tool")
  assert(by_name["write"], "should have write tool")
  assert(by_name["edit"], "should have edit tool")
  assert(by_name["bash"], "should have bash tool")
  print("✓ tool definitions are correct")
end
test_tool_definitions()

local function test_read_tool()
  local test_file = fs.join(TEST_TMPDIR, "test_read_tool.txt")
  cio.barf(test_file, "test-hostname\n")
  local result, is_error, details = tools.execute_tool("read", {path = test_file})
  assert(not is_error, "read should succeed: " .. result)
  assert(result:match("1\t"), "should have line numbers")
  assert(details, "read should return details")
  assert(details.path == test_file, "details should have path")
  print("✓ read tool works")
end
test_read_tool()

local function test_read_nonexistent()
  local result, is_error = tools.execute_tool("read", {path = "/nonexistent/file"})
  assert(is_error, "should fail for nonexistent file")
  assert(result:match("error"), "should return error message")
  print("✓ read tool handles missing files")
end
test_read_nonexistent()

local function test_write_tool()
  local test_file = fs.join(TEST_TMPDIR, "test_write.txt")
  local result, is_error, details = tools.execute_tool("write", {path = test_file, content = "hello world"})
  assert(not is_error, "write should succeed: " .. result)
  assert(details and details.bytes == 11, "details should have bytes")
  print("✓ write tool works")
end
test_write_tool()

local function test_edit_tool()
  local test_file = fs.join(TEST_TMPDIR, "test_edit.txt")
  tools.execute_tool("write", {path = test_file, content = "hello world"})
  local result, is_error, details = tools.execute_tool("edit", {path = test_file, old_string = "hello", new_string = "goodbye"})
  assert(not is_error, "edit should succeed: " .. result)
  assert(details and details.path == test_file, "details should have path")
  local content, _ = tools.execute_tool("read", {path = test_file})
  assert(content:match("goodbye world"), "content should be changed")
  print("✓ edit tool works")
end
test_edit_tool()

local function test_edit_tool_percent_in_replacement()
  local test_file = fs.join(TEST_TMPDIR, "test_edit_percent.txt")
  tools.execute_tool("write", {path = test_file, content = "value = 100"})
  local result, is_error = tools.execute_tool("edit", {path = test_file, old_string = "100", new_string = "50%"})
  assert(not is_error, "edit with % should succeed: " .. (result or "nil"))
  local content, _ = tools.execute_tool("read", {path = test_file})
  assert(content:match("value = 50%%"), "content should have 50%")
  print("✓ edit tool handles % in replacement string")
end
test_edit_tool_percent_in_replacement()

local function test_bash_tool()
  local result, is_error, details = tools.execute_tool("bash", {command = "echo hello"})
  assert(not is_error, "bash should succeed")
  assert(result:match("hello"), "should capture stdout")
  assert(details and details.exit_code == 0, "exit_code should be 0")
  print("✓ bash tool works")
end
test_bash_tool()

local function test_bash_exit_code()
  local result, is_error, details = tools.execute_tool("bash", {command = "exit 1"})
  assert(is_error, "should report error for non-zero exit")
  assert(result:match("exit code: 1"), "should report exit code")
  assert(details and details.exit_code == 1, "exit_code should be 1")
  print("✓ bash tool handles exit codes")
end
test_bash_exit_code()

local function test_bash_timeout()
  local result, is_error = tools.execute_tool("bash", {command = "sleep 5", timeout = 1000})
  assert(is_error, "should report error for timeout")
  assert(result:match("timed out"), "should indicate timeout")
  print("✓ bash timeout works")
end
test_bash_timeout()

local function test_bash_timeout_not_triggered()
  local result, is_error = tools.execute_tool("bash", {command = "echo fast", timeout = 5000})
  assert(not is_error, "quick command should succeed")
  assert(result:match("fast"), "should capture output")
  print("✓ bash timeout does not affect fast commands")
end
test_bash_timeout_not_triggered()

local function test_bash_env_passthrough()
  local home = os.getenv("HOME")
  assert(home, "HOME should be set")
  local result, is_error = tools.execute_tool("bash", {command = "echo $HOME"})
  assert(not is_error, "bash should succeed")
  assert(result:match(home), "child should see HOME")
  print("✓ bash tool passes environment variables")
end
test_bash_env_passthrough()

local function test_bash_newline_in_command()
  local result, is_error = tools.execute_tool("bash", {command = "echo line1\necho line2"})
  assert(not is_error, "multiline should succeed")
  assert(result:match("line1"), "should have line1")
  assert(result:match("line2"), "should have line2")
  print("✓ bash handles newlines in commands")
end
test_bash_newline_in_command()

local function test_bash_brace_expansion()
  local result, is_error = tools.execute_tool("bash", {command = "echo {a,b,c}"})
  assert(not is_error, "brace expansion should succeed")
  assert(result:match("a b c"), "should expand braces: " .. result)
  print("✓ bash handles brace expansion")
end
test_bash_brace_expansion()

-- Project tool loading

local function test_custom_tool_override()
  local project = fs.join(TEST_TMPDIR, "override_project")
  local project_tools = fs.join(project, "tools")
  fs.makedirs(project_tools)
  cio.barf(fs.join(project_tools, "foo.lua"), [[
return {
  name = "foo", description = "project foo",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "project", false end,
}
]])
  tools.init_custom_tools(project)
  local result, is_error = tools.execute_tool("foo", {})
  assert(not is_error, "project tool should execute")
  assert(result == "project", "should run project tool")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent_project"))
  print("✓ project tools loaded from cwd/tools/")
end
test_custom_tool_override()

local function test_project_tools_no_dir()
  local empty_project = fs.join(TEST_TMPDIR, "empty_project_tools")
  fs.makedirs(empty_project)
  tools.init_custom_tools(empty_project)
  local defs = tools.get_tool_definitions()
  assert(#defs >= 4, "should still have builtin tools")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent_project"))
  print("✓ init_custom_tools handles missing tools/ directory")
end
test_project_tools_no_dir()

local function test_dot_ah_tools_wins()
  local project = fs.join(TEST_TMPDIR, "dot_ah_tools_project")
  fs.makedirs(fs.join(project, "tools"))
  fs.makedirs(fs.join(project, ".ah", "tools"))
  cio.barf(fs.join(project, "tools", "pick.lua"), [[
return { name = "pick", description = "bare", input_schema = {type = "object", properties = {}, required = {}}, execute = function() return "from-bare", false end }
]])
  cio.barf(fs.join(project, ".ah", "tools", "pick.lua"), [[
return { name = "pick", description = "dot-ah", input_schema = {type = "object", properties = {}, required = {}}, execute = function() return "from-dot-ah", false end }
]])
  tools.init_custom_tools(project)
  local result, _ = tools.execute_tool("pick", {})
  assert(result == "from-dot-ah", ".ah/tools should win: " .. result)
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ .ah/tools takes precedence over tools/")
end
test_dot_ah_tools_wins()

local function test_bare_tools_when_no_dot_ah()
  local project = fs.join(TEST_TMPDIR, "bare_tools_only")
  fs.makedirs(fs.join(project, "tools"))
  cio.barf(fs.join(project, "tools", "bare.lua"), [[
return { name = "bare", description = "bare tool", input_schema = {type = "object", properties = {}, required = {}}, execute = function() return "from-bare", false end }
]])
  tools.init_custom_tools(project)
  local result, _ = tools.execute_tool("bare", {})
  assert(result == "from-bare", "should load from tools/")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ tools/ used as fallback")
end
test_bare_tools_when_no_dot_ah()

-- Image tests

local function test_read_image_png()
  local png_data = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137\0\0\0\nIDATx\156c\0\1\0\0\5\0\1\r\10-\180\0\0\0\0IEND\174B`\130"
  local png_path = fs.join(TEST_TMPDIR, "test.png")
  cio.barf(png_path, png_data)
  local result, is_error = tools.execute_tool("read", {path = png_path})
  assert(not is_error, "should read image")
  local parsed = json.decode(result) as {string: any}
  assert(parsed and parsed.__image__ == true, "should have __image__ marker")
  print("✓ read tool handles PNG images")
end
test_read_image_png()

local function test_read_image_jpg()
  cio.barf(fs.join(TEST_TMPDIR, "test.jpg"), "fake jpg content")
  local result, is_error = tools.execute_tool("read", {path = fs.join(TEST_TMPDIR, "test.jpg")})
  assert(not is_error, "should read jpg")
  local parsed = json.decode(result) as {string: any}
  assert(parsed and parsed.__image__ == true, "should have __image__ marker")
  print("✓ read tool handles JPEG images")
end
test_read_image_jpg()

local function test_read_text_not_image()
  cio.barf(fs.join(TEST_TMPDIR, "test_not_img.txt"), "hello world")
  local result, is_error = tools.execute_tool("read", {path = fs.join(TEST_TMPDIR, "test_not_img.txt")})
  assert(not is_error, "should read txt")
  assert(not result:match("__image__"), "txt should not be treated as image")
  print("✓ read tool treats .txt as text")
end
test_read_text_not_image()

local function test_read_binary_file()
  cio.barf(fs.join(TEST_TMPDIR, "test.bin"), "MZ\0\0PE\0\0binary content\0\0more")
  local result, is_error = tools.execute_tool("read", {path = fs.join(TEST_TMPDIR, "test.bin")})
  assert(is_error, "should report error for binary file")
  assert(result:match("binary"), "should mention binary")
  print("✓ read tool detects binary files")
end
test_read_binary_file()

-- Validation tests

local function test_validate_input_valid()
  local schema = {type = "object", properties = {name = {type = "string"}, age = {type = "integer"}}, required = {"name"}}
  local err = tools.validate_input(schema, {name = "Alice", age = 30})
  assert(err == nil, "valid input should pass: " .. tostring(err))
  print("✓ validate_input accepts valid input")
end
test_validate_input_valid()

local function test_validate_input_missing_required()
  local schema = {type = "object", properties = {name = {type = "string"}}, required = {"name"}}
  local err = tools.validate_input(schema, {})
  assert(err and err:match("missing required"), "should report missing required")
  print("✓ validate_input catches missing required")
end
test_validate_input_missing_required()

local function test_validate_input_wrong_type()
  local schema = {type = "object", properties = {name = {type = "string"}}, required = {}}
  local err = tools.validate_input(schema, {name = 42})
  assert(err and err:match("expected string"), "should report type mismatch")
  print("✓ validate_input catches wrong type")
end
test_validate_input_wrong_type()

local function test_execute_tool_validation_error()
  local result, is_error = tools.execute_tool("read", {})
  assert(is_error, "missing required param should fail")
  assert(result:match("missing required"), "should report validation error")
  print("✓ execute_tool returns validation errors")
end
test_execute_tool_validation_error()

-- Override tests

local function test_add_tool_override()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local tool_dir = fs.join(TEST_TMPDIR, "override_tool")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "my-tool.lua"), [[
return {
  name = "my-tool", description = "An override tool",
  input_schema = {type = "object", properties = {who = {type = "string"}}, required = {}},
  execute = function(input) return "hello from override " .. (input.who or "world"), false end,
}
]])
  tools.add_tool_override("my-tool", fs.join(tool_dir, "my-tool.lua"))
  local result, is_error = tools.execute_tool("my-tool", {who = "world"})
  assert(not is_error, "override tool should execute")
  assert(result:match("hello from override world"), "should run override")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ add_tool_override registers a tool")
end
test_add_tool_override()

local function test_add_tool_override_replaces_existing()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local tool_dir = fs.join(TEST_TMPDIR, "override_bash")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "fake-bash.lua"), [[
return { name = "bash", description = "Fake bash",
  input_schema = {type = "object", properties = {command = {type = "string"}}, required = {}},
  execute = function() return "replaced", false end }
]])
  tools.add_tool_override("bash", fs.join(tool_dir, "fake-bash.lua"))
  local result, _ = tools.execute_tool("bash", {command = ""})
  assert(result:match("replaced"), "should run override")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ add_tool_override replaces existing tool")
end
test_add_tool_override_replaces_existing()

local function test_add_tool_override_rejects_non_module()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local defs_before = #tools.get_tool_definitions()
  tools.add_tool_override("deploy", "/usr/bin/echo")
  assert(defs_before == #tools.get_tool_definitions(), "non-module should not be added")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ add_tool_override rejects non .tl/.lua files")
end
test_add_tool_override_rejects_non_module()

local function test_remove_tool()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local removed = tools.remove_tool("bash")
  assert(removed, "should return true for existing tool")
  local result, is_error = tools.execute_tool("bash", {command = "echo hi"})
  assert(is_error, "executing removed tool should error")
  local removed2 = tools.remove_tool("nonexistent-tool")
  assert(not removed2, "should return false for missing tool")
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ remove_tool removes a tool by name")
end
test_remove_tool()

local function test_format_tools_for_prompt_builtin()
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  local prompt = tools.format_tools_for_prompt()
  assert(prompt:match("Tools:"), "should have Tools: header")
  assert(prompt:match("bash"), "should list bash")
  assert(prompt:match("read"), "should list read")
  print("✓ format_tools_for_prompt lists builtins")
end
test_format_tools_for_prompt_builtin()

-- String integer coercion

local function test_string_integer_coercion()
  local test_file = fs.join(TEST_TMPDIR, "coerce_test.txt")
  cio.barf(test_file, "line1\nline2\nline3\nline4\nline5\n")
  local result, is_error = tools.execute_tool("read", {path = test_file, offset = "2" as any, limit = "2" as any})
  assert(not is_error, "string integers should be coerced")
  assert(result:match("2\t"), "should start at line 2")
  print("✓ string integer coercion works")
end
test_string_integer_coercion()

local function test_bash_timeout_string_coercion()
  local result, is_error = tools.execute_tool("bash", {command = "echo fast", timeout = "5000" as any})
  assert(not is_error, "string timeout should be coerced")
  assert(result:match("fast"), "should work with coerced timeout")
  print("✓ bash timeout string coercion works")
end
test_bash_timeout_string_coercion()

local function test_abort_no_processes()
  tools.abort_running_tools()
  print("✓ abort with no running processes is safe")
end
test_abort_no_processes()

-- Skill tool require tests

local function test_skill_tool_requires_project_module()
  local project = fs.join(TEST_TMPDIR, "skill_cwd_require")
  fs.makedirs(fs.join(project, "lib"))
  fs.makedirs(fs.join(project, "skills", "myskill", "tools"))
  cio.barf(fs.join(project, "lib", "shared.lua"), [[
return { value = function() return "from-shared-lib" end }
]])
  cio.barf(fs.join(project, "skills", "myskill", "tools", "myskill.lua"), [[
local shared = require("lib.shared")
return { name = "myskill", description = "Skill tool that uses shared lib",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return shared.value(), false end }
]])
  tools.init_custom_tools(project)
  local orig_dir = fs.getcwd()
  fs.chdir(project)
  tools.load_skill_tools(fs.join(project, "skills", "myskill"))
  fs.chdir(orig_dir)
  local result, is_error = tools.execute_tool("myskill", {})
  assert(not is_error, "skill tool should execute: " .. tostring(result))
  assert(result == "from-shared-lib", "should require project module")
  package.loaded["lib.shared"] = nil
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ skill tools can require() from project root")
end
test_skill_tool_requires_project_module()

local function test_add_tool_override_require()
  local tool_dir = fs.join(TEST_TMPDIR, "override_require")
  fs.makedirs(tool_dir)
  cio.barf(fs.join(tool_dir, "ovr_helper.lua"), [[return { msg = function() return "from-helper" end }]])
  cio.barf(fs.join(tool_dir, "ovr_tool.lua"), [[
local ovr_helper = require("ovr_helper")
return { name = "ovr_tool", description = "Override tool with require",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return ovr_helper.msg(), false end }
]])
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  tools.add_tool_override("ovr_tool", fs.join(tool_dir, "ovr_tool.lua"))
  local result, is_error = tools.execute_tool("ovr_tool", {})
  assert(not is_error, "override tool should succeed")
  assert(result == "from-helper", "should use helper via require")
  package.loaded["ovr_helper"] = nil
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ add_tool_override enables sibling requires")
end
test_add_tool_override_require()

print("\nAll tools tests passed!")
