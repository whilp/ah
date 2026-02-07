#!/usr/bin/env cosmic
-- test_tools.tl: tests for agent tools
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
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
    execute = function(_: {string:any}): string, boolean return "ok", false end,
  }
  assert(tools.is_valid_tool(valid), "valid tool should pass validation")
  print("✓ is_valid_tool works")
end
test_is_valid_tool()

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
  local tool_dir = fs.join(TEST_TMPDIR, "custom_tools")
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
  local tool_dir = fs.join(TEST_TMPDIR, "invalid_tools")
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

local function test_custom_tool_override()
  local global_dir = fs.join(TEST_TMPDIR, "global_tools")
  local project_dir = fs.join(TEST_TMPDIR, "project_tools")
  fs.makedirs(global_dir)
  fs.makedirs(project_dir)

  cio.barf(fs.join(global_dir, "foo.lua"), [[
return {
  name = "foo",
  description = "global foo",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "global", false end,
}
]])

  cio.barf(fs.join(project_dir, "foo.lua"), [[
return {
  name = "foo",
  description = "project foo",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "project", false end,
}
]])

  local all = tools.load_custom_tools(global_dir, project_dir)
  local foo: tools.Tool = nil
  for _, t in ipairs(all) do
    if t.name == "foo" then foo = t end
  end
  assert(foo, "should have foo tool")
  assert(foo.description == "project foo", "project should override global")
  print("✓ project tools override global tools")
end
test_custom_tool_override()

-- Bash timeout tests
local function test_bash_timeout()
  -- Use a short timeout (1 second) on a command that would take longer
  local result, is_error = tools.execute_tool("bash", {command = "sleep 5", timeout = 1000})
  assert(is_error, "should report error for timeout")
  assert(result:match("timed out"), "should indicate timeout: " .. result)
  print("✓ bash timeout works")
end
test_bash_timeout()

local function test_bash_timeout_not_triggered()
  -- Quick command should not timeout
  local result, is_error = tools.execute_tool("bash", {command = "echo fast", timeout = 5000})
  assert(not is_error, "quick command should succeed")
  assert(result:match("fast"), "should capture output")
  assert(not result:match("timed out"), "should not timeout")
  print("✓ bash timeout does not affect fast commands")
end
test_bash_timeout_not_triggered()

-- CLI tool tests
local function test_load_cli_tools_empty_dir()
  local empty_dir = fs.join(TEST_TMPDIR, "empty_bin")
  fs.makedirs(empty_dir)

  local loaded = tools.load_cli_tools_from_dir(empty_dir)
  assert(#loaded == 0, "should load 0 tools from empty dir")
  print("✓ load_cli_tools handles empty directory")
end
test_load_cli_tools_empty_dir()

local function test_load_cli_tools_nonexistent()
  local loaded = tools.load_cli_tools_from_dir("/nonexistent/bin")
  assert(#loaded == 0, "should return empty for nonexistent dir")
  print("✓ load_cli_tools handles nonexistent directory")
end
test_load_cli_tools_nonexistent()

local function test_load_cli_tool_with_md()
  local bin_dir = fs.join(TEST_TMPDIR, "cli_tools_md")
  fs.makedirs(bin_dir)

  -- Create executable script
  local script_path = fs.join(bin_dir, "greet")
  cio.barf(script_path, [[#!/bin/sh
echo "Hello, $1!"
]], tonumber("755", 8))

  -- Create description file
  cio.barf(fs.join(bin_dir, "greet.md"), "Greet someone by name\n\nUsage: greet <name>")

  local loaded = tools.load_cli_tools_from_dir(bin_dir)
  assert(#loaded == 1, "should load 1 tool")
  assert(loaded[1].name == "greet", "tool name should be greet")
  assert(loaded[1].description == "Greet someone by name", "should use first paragraph from md")

  local result, is_error = loaded[1].execute({args = "World"})
  assert(not is_error, "should execute successfully")
  assert(result:match("Hello, World!"), "should run command: " .. result)
  print("✓ load_cli_tools loads tool with .md description")
end
test_load_cli_tool_with_md()

local function test_load_cli_tool_with_help()
  local bin_dir = fs.join(TEST_TMPDIR, "cli_tools_help")
  fs.makedirs(bin_dir)

  -- Create executable that responds to --help
  local script_path = fs.join(bin_dir, "helper")
  cio.barf(script_path, [[#!/bin/sh
if [ "$1" = "--help" ]; then
  echo "A helpful utility"
  exit 0
fi
echo "running: $@"
]], tonumber("755", 8))

  local loaded = tools.load_cli_tools_from_dir(bin_dir)
  assert(#loaded == 1, "should load 1 tool")
  assert(loaded[1].name == "helper", "tool name should be helper")
  assert(loaded[1].description == "A helpful utility", "should use --help output")
  print("✓ load_cli_tools uses --help for description")
end
test_load_cli_tool_with_help()

local function test_cli_tool_override()
  local global_dir = fs.join(TEST_TMPDIR, "global_bin")
  local project_dir = fs.join(TEST_TMPDIR, "project_bin")
  fs.makedirs(global_dir)
  fs.makedirs(project_dir)

  cio.barf(fs.join(global_dir, "mytool"), "#!/bin/sh\necho global", tonumber("755", 8))
  cio.barf(fs.join(global_dir, "mytool.md"), "Global version")

  cio.barf(fs.join(project_dir, "mytool"), "#!/bin/sh\necho project", tonumber("755", 8))
  cio.barf(fs.join(project_dir, "mytool.md"), "Project version")

  local all = tools.load_cli_tools(global_dir, project_dir)
  local mytool: tools.Tool = nil
  for _, t in ipairs(all) do
    if t.name == "mytool" then mytool = t end
  end
  assert(mytool, "should have mytool")
  assert(mytool.description == "Project version", "project should override global")

  local result, _ = mytool.execute({})
  assert(result:match("project"), "should run project version")
  print("✓ project CLI tools override global CLI tools")
end
test_cli_tool_override()

-- Image read tests
local json = require("cosmic.json")

local function test_read_image_png()
  -- Create a minimal valid PNG (1x1 transparent pixel)
  local png_data = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137\0\0\0\nIDATx\156c\0\1\0\0\5\0\1\r\10-\180\0\0\0\0IEND\174B`\130"
  local png_path = fs.join(TEST_TMPDIR, "test.png")
  cio.barf(png_path, png_data)

  local result, is_error = tools.execute_tool("read", {path = png_path})
  assert(not is_error, "should read image successfully")

  local parsed = json.decode(result) as {string:any}
  assert(parsed, "result should be valid JSON")
  assert(parsed.__image__ == true, "should have __image__ marker")
  assert(parsed.content, "should have content array")

  local content = (parsed.content as {any})[1] as {string:any}
  assert(content.type == "image", "content type should be image")
  assert(content.source, "should have source")

  local source = content.source as {string:any}
  assert(source.type == "base64", "source type should be base64")
  assert(source.media_type == "image/png", "media type should be image/png")
  assert(source.data and #(source.data as string) > 0, "should have base64 data")
  print("✓ read tool handles PNG images")
end
test_read_image_png()

local function test_read_image_jpg()
  -- Create a minimal JPEG (not valid image but has correct extension)
  local jpg_path = fs.join(TEST_TMPDIR, "test.jpg")
  cio.barf(jpg_path, "fake jpg content")

  local result, is_error = tools.execute_tool("read", {path = jpg_path})
  assert(not is_error, "should read jpg successfully")

  local parsed = json.decode(result) as {string:any}
  assert(parsed.__image__ == true, "should have __image__ marker")

  local content = (parsed.content as {any})[1] as {string:any}
  local source = content.source as {string:any}
  assert(source.media_type == "image/jpeg", "media type should be image/jpeg")
  print("✓ read tool handles JPEG images")
end
test_read_image_jpg()

local function test_read_image_webp()
  local webp_path = fs.join(TEST_TMPDIR, "test.webp")
  cio.barf(webp_path, "fake webp content")

  local result, is_error = tools.execute_tool("read", {path = webp_path})
  assert(not is_error, "should read webp successfully")

  local parsed = json.decode(result) as {string:any}
  local content = (parsed.content as {any})[1] as {string:any}
  local source = content.source as {string:any}
  assert(source.media_type == "image/webp", "media type should be image/webp")
  print("✓ read tool handles WebP images")
end
test_read_image_webp()

local function test_read_image_gif()
  local gif_path = fs.join(TEST_TMPDIR, "test.gif")
  cio.barf(gif_path, "GIF89a fake")

  local result, is_error = tools.execute_tool("read", {path = gif_path})
  assert(not is_error, "should read gif successfully")

  local parsed = json.decode(result) as {string:any}
  local content = (parsed.content as {any})[1] as {string:any}
  local source = content.source as {string:any}
  assert(source.media_type == "image/gif", "media type should be image/gif")
  print("✓ read tool handles GIF images")
end
test_read_image_gif()

local function test_read_text_not_image()
  -- Ensure .txt files are still treated as text
  local txt_path = fs.join(TEST_TMPDIR, "test.txt")
  cio.barf(txt_path, "hello world")

  local result, is_error = tools.execute_tool("read", {path = txt_path})
  assert(not is_error, "should read txt successfully")
  assert(not result:match("__image__"), "txt should not be treated as image")
  assert(result:match("1\t"), "should have line numbers")
  assert(result:match("hello world"), "should have content")
  print("✓ read tool treats .txt as text, not image")
end
test_read_text_not_image()

-- Tool name normalization tests (for OAuth mode)
local function test_to_claude_code_name()
  assert(tools.to_claude_code_name("read") == "Read", "read -> Read")
  assert(tools.to_claude_code_name("write") == "Write", "write -> Write")
  assert(tools.to_claude_code_name("edit") == "Edit", "edit -> Edit")
  assert(tools.to_claude_code_name("bash") == "Bash", "bash -> Bash")
  assert(tools.to_claude_code_name("custom") == "custom", "unknown names unchanged")
  print("✓ to_claude_code_name works")
end
test_to_claude_code_name()

local function test_from_claude_code_name()
  assert(tools.from_claude_code_name("Read") == "read", "Read -> read")
  assert(tools.from_claude_code_name("Write") == "write", "Write -> write")
  assert(tools.from_claude_code_name("Edit") == "edit", "Edit -> edit")
  assert(tools.from_claude_code_name("Bash") == "bash", "Bash -> bash")
  assert(tools.from_claude_code_name("Custom") == "Custom", "unknown names unchanged")
  print("✓ from_claude_code_name works")
end
test_from_claude_code_name()

local function test_get_tool_definitions_oauth()
  local defs_normal = tools.get_tool_definitions(false)
  local defs_oauth = tools.get_tool_definitions(true)

  assert(#defs_normal == #defs_oauth, "should have same number of tools")

  -- Find read tool in each
  local read_normal: {string:any} = nil
  local read_oauth: {string:any} = nil
  for _, d in ipairs(defs_normal) do
    if (d as {string:any}).name == "read" then read_normal = d as {string:any} end
  end
  for _, d in ipairs(defs_oauth) do
    if (d as {string:any}).name == "Read" then read_oauth = d as {string:any} end
  end

  assert(read_normal, "should have read tool in normal mode")
  assert(read_oauth, "should have Read tool in oauth mode")
  print("✓ get_tool_definitions handles oauth mode")
end
test_get_tool_definitions_oauth()

print("\nAll tools tests passed!")
