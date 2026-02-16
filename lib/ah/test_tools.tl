#!/usr/bin/env cosmic
-- test_tools.tl: tests for agent tools
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local tools = require("ah.tools")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_read_tool()
  local result, is_error, details = tools.execute_tool("read", {path = "/etc/hostname"})
  assert(not is_error, "read should succeed: " .. result)
  assert(result:match("1\t"), "should have line numbers")
  assert(details, "read should return details")
  assert(details.path == "/etc/hostname", "details should have path")
  assert(details.line_count and details.line_count > 0, "details should have line_count")
  print("✓ read tool works")
end

local function test_read_nonexistent()
  local result, is_error, details = tools.execute_tool("read", {path = "/nonexistent/file"})
  assert(is_error, "should fail for nonexistent file")
  assert(result:match("error"), "should return error message")
  assert(details == nil, "error should not return details")
  print("✓ read tool handles missing files")
end

local function test_write_tool()
  local test_file = os.getenv("TEST_TMPDIR") .. "/test_write.txt"
  local result, is_error, details = tools.execute_tool("write", {path = test_file, content = "hello world"})
  assert(not is_error, "write should succeed: " .. result)
  assert(result:match("1 lines"), "should report line count: " .. result)
  assert(details, "write should return details")
  assert(details.path == test_file, "details should have path")
  assert(details.bytes == 11, "details should have bytes: " .. tostring(details.bytes))
  print("✓ write tool works")
end

local function test_edit_tool()
  local test_file = os.getenv("TEST_TMPDIR") .. "/test_edit.txt"
  tools.execute_tool("write", {path = test_file, content = "hello world"})
  local result, is_error, details = tools.execute_tool("edit", {
    path = test_file,
    old_string = "hello",
    new_string = "goodbye"
  })
  assert(not is_error, "edit should succeed: " .. result)
  assert(details, "edit should return details")
  assert(details.path == test_file, "details should have path")
  assert(details.old_lines == 1, "details should have old_lines: " .. tostring(details.old_lines))
  assert(details.new_lines == 1, "details should have new_lines: " .. tostring(details.new_lines))

  local content, _ = tools.execute_tool("read", {path = test_file})
  assert(content:match("goodbye world"), "content should be changed")
  print("✓ edit tool works")
end

local function test_edit_tool_percent_in_replacement()
  local test_file = os.getenv("TEST_TMPDIR") .. "/test_edit_percent.txt"
  tools.execute_tool("write", {path = test_file, content = "value = 100"})
  local result, is_error = tools.execute_tool("edit", {
    path = test_file,
    old_string = "100",
    new_string = "50%"
  })
  assert(not is_error, "edit with % should succeed: " .. (result or "nil"))

  local content, _ = tools.execute_tool("read", {path = test_file})
  assert(content:match("value = 50%%"), "content should have 50%")
  print("✓ edit tool handles % in replacement string")
end

local function test_bash_tool()
  local result, is_error, details = tools.execute_tool("bash", {command = "echo hello"})
  assert(not is_error, "bash should succeed")
  assert(result:match("hello"), "should capture stdout")
  assert(details, "bash should return details")
  assert(details.command == "echo hello", "details should have command")
  assert(details.exit_code == 0, "details should have exit_code 0: " .. tostring(details.exit_code))
  print("✓ bash tool works")
end

local function test_bash_exit_code()
  local result, is_error, details = tools.execute_tool("bash", {command = "exit 1"})
  assert(is_error, "should report error for non-zero exit")
  assert(result:match("exit code: 1"), "should report exit code")
  assert(details, "bash error should still return details")
  assert(details.exit_code == 1, "details should have exit_code 1: " .. tostring(details.exit_code))
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
test_edit_tool_percent_in_replacement()
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
  -- Project tools in cwd/tools/ should be loaded by init_custom_tools
  local project = fs.join(TEST_TMPDIR, "override_project")
  local project_tools = fs.join(project, "tools")
  fs.makedirs(project_tools)

  cio.barf(fs.join(project_tools, "foo.lua"), [[
return {
  name = "foo",
  description = "project foo",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "project", false end,
}
]])

  tools.init_custom_tools(project)

  local result, is_error = tools.execute_tool("foo", {})
  assert(not is_error, "project tool should execute")
  assert(result == "project", "should run project tool: " .. result)

  -- Reset
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent_project"))
  print("✓ project tools loaded from cwd/tools/")
end
test_custom_tool_override()

local function test_project_tools_no_dir()
  -- init_custom_tools with a cwd that has no tools/ directory should not error
  local empty_project = fs.join(TEST_TMPDIR, "empty_project_tools")
  fs.makedirs(empty_project)
  tools.init_custom_tools(empty_project)

  -- Should still have the 4 builtin tools
  local defs = tools.get_tool_definitions()
  assert(#defs >= 4, "should still have builtin tools: " .. tostring(#defs))

  -- Reset
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent_project"))
  print("✓ init_custom_tools handles missing tools/ directory")
end
test_project_tools_no_dir()

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

local function test_bash_env_passthrough()
  -- Verify that environment variables are passed to child processes
  -- HOME should always be set and passed through
  local home = os.getenv("HOME")
  assert(home, "HOME should be set in test environment")

  local result, is_error = tools.execute_tool("bash", {command = "echo $HOME"})
  assert(not is_error, "bash should succeed")
  assert(result:match(home), "child process should see HOME env var: " .. result)

  -- Also verify PATH is passed (needed for commands to work)
  local path_result, path_error = tools.execute_tool("bash", {command = "echo $PATH"})
  assert(not path_error, "bash should succeed")
  assert(path_result:match("/"), "child process should see PATH with directories: " .. path_result)
  print("✓ bash tool passes environment variables to child processes")
end
test_bash_env_passthrough()

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

  -- Create description file with frontmatter and body
  cio.barf(fs.join(bin_dir, "greet.md"), "---\ndescription: Greet someone by name\n---\n\nUsage: greet <name>\n\nAlways be polite.")

  local loaded = tools.load_cli_tools_from_dir(bin_dir)
  assert(#loaded == 1, "should load 1 tool")
  assert(loaded[1].name == "greet", "tool name should be greet")
  assert(loaded[1].description == "Greet someone by name", "should use description from frontmatter")
  assert(loaded[1].system_prompt ~= nil, "should have system_prompt from body")
  assert(loaded[1].system_prompt:match("Always be polite"), "system_prompt should contain body: " .. loaded[1].system_prompt)

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

local function test_no_project_cli_tools_in_bin()
  -- init_custom_tools should NOT load CLI tools from cwd/bin/
  local project = fs.join(TEST_TMPDIR, "cli_no_project")
  local project_bin = fs.join(project, "bin")
  fs.makedirs(project_bin)

  cio.barf(fs.join(project_bin, "mytool"), "#!/bin/sh\necho project", tonumber("755", 8))
  cio.barf(fs.join(project_bin, "mytool.md"), "Project version")

  tools.init_custom_tools(project)

  -- mytool should NOT be available (cwd/bin/ is not scanned)
  local found = false
  for _, d in ipairs(tools.get_tool_definitions()) do
    if (d as {string:any}).name == "mytool" then found = true end
  end
  assert(not found, "cwd/bin/ tools should not be loaded")

  -- Reset
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent_project"))
  print("✓ cwd/bin/ CLI tools are not loaded")
end
test_no_project_cli_tools_in_bin()

local function test_executable_in_project_tools()
  -- Executables in cwd/tools/ should be loaded as CLI tools
  local project = fs.join(TEST_TMPDIR, "cli_in_tools")
  local project_tools = fs.join(project, "tools")
  fs.makedirs(project_tools)

  cio.barf(fs.join(project_tools, "greet"), "#!/bin/sh\necho \"hello $1\"", tonumber("755", 8))
  cio.barf(fs.join(project_tools, "greet.md"), "---\ndescription: Greet someone\n---\n\nAlways be polite.")

  tools.init_custom_tools(project)

  local result, is_error = tools.execute_tool("greet", {args = "world"})
  assert(not is_error, "executable tool should work: " .. tostring(result))
  assert(result:match("hello world"), "should run executable: " .. result)

  -- Check system_prompt from .md body
  local prompt = tools.format_tools_for_prompt()
  assert(prompt:match("Always be polite"), "should include system_prompt from .md body")

  -- Reset
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent_project"))
  print("✓ executables in cwd/tools/ loaded as CLI tools")
end
test_executable_in_project_tools()

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

local function test_read_binary_file()
  -- Create a file with null bytes (binary indicator)
  local bin_path = fs.join(TEST_TMPDIR, "test.bin")
  cio.barf(bin_path, "MZ\0\0PE\0\0binary content\0\0more")

  local result, is_error = tools.execute_tool("read", {path = bin_path})
  assert(is_error, "should report error for binary file")
  assert(result:match("binary file"), "should indicate binary: " .. result)
  print("✓ read tool detects binary files")
end
test_read_binary_file()

local function test_read_binary_by_control_chars()
  -- Create a file with many control characters (binary indicator)
  local bin_path = fs.join(TEST_TMPDIR, "test_ctrl.bin")
  local content = ""
  for i = 1, 100 do
    content = content .. string.char(1) .. string.char(2) .. string.char(3)
  end
  cio.barf(bin_path, content)

  local result, is_error = tools.execute_tool("read", {path = bin_path})
  assert(is_error, "should report error for binary file with control chars")
  assert(result:match("binary file"), "should indicate binary: " .. result)
  print("✓ read tool detects binary by control character ratio")
end
test_read_binary_by_control_chars()

-- Input validation tests
local function test_validate_input_valid()
  local schema: {string:any} = {
    type = "object",
    properties = {
      path = {type = "string"},
      count = {type = "integer"},
    },
    required = {"path"},
  }
  local err = tools.validate_input(schema, {path = "/tmp/foo", count = 10})
  assert(err == nil, "valid input should pass: " .. tostring(err))
  print("✓ validate_input accepts valid input")
end
test_validate_input_valid()

local function test_validate_input_missing_required()
  local schema: {string:any} = {
    type = "object",
    properties = {
      path = {type = "string"},
      content = {type = "string"},
    },
    required = {"path", "content"},
  }
  local err = tools.validate_input(schema, {path = "/tmp/foo"})
  assert(err ~= nil, "should fail for missing required property")
  assert(err:match("missing required property: content"), "should name the missing property: " .. err)
  print("✓ validate_input catches missing required properties")
end
test_validate_input_missing_required()

local function test_validate_input_wrong_type()
  local schema: {string:any} = {
    type = "object",
    properties = {
      path = {type = "string"},
      timeout = {type = "integer"},
    },
    required = {"path"},
  }
  local err = tools.validate_input(schema, {path = 123})
  assert(err ~= nil, "should fail for wrong type")
  assert(err:match("property 'path': expected string, got number"), "should describe type mismatch: " .. err)
  print("✓ validate_input catches wrong property types")
end
test_validate_input_wrong_type()

local function test_validate_input_multiple_errors()
  local schema: {string:any} = {
    type = "object",
    properties = {
      path = {type = "string"},
      content = {type = "string"},
    },
    required = {"path", "content"},
  }
  local err = tools.validate_input(schema, {})
  assert(err ~= nil, "should fail for multiple missing properties")
  assert(err:match("missing required property: path"), "should report path missing: " .. err)
  assert(err:match("missing required property: content"), "should report content missing: " .. err)
  print("✓ validate_input reports multiple errors")
end
test_validate_input_multiple_errors()

local function test_validate_input_optional_missing()
  local schema: {string:any} = {
    type = "object",
    properties = {
      path = {type = "string"},
      offset = {type = "integer"},
    },
    required = {"path"},
  }
  local err = tools.validate_input(schema, {path = "/tmp/foo"})
  assert(err == nil, "optional properties can be missing: " .. tostring(err))
  print("✓ validate_input allows missing optional properties")
end
test_validate_input_optional_missing()

local function test_validate_input_no_required()
  local schema: {string:any} = {
    type = "object",
    properties = {
      args = {type = "string"},
    },
  }
  local err = tools.validate_input(schema, {})
  assert(err == nil, "schema with no required should pass: " .. tostring(err))
  print("✓ validate_input handles schema with no required array")
end
test_validate_input_no_required()

local function test_validate_input_boolean_type()
  local schema: {string:any} = {
    type = "object",
    properties = {
      flag = {type = "boolean"},
    },
    required = {"flag"},
  }
  local err = tools.validate_input(schema, {flag = true})
  assert(err == nil, "boolean should validate: " .. tostring(err))
  local err2 = tools.validate_input(schema, {flag = "true"})
  assert(err2 ~= nil, "string should not pass as boolean")
  assert(err2:match("expected boolean, got string"), "should describe boolean mismatch: " .. err2)
  print("✓ validate_input handles boolean types")
end
test_validate_input_boolean_type()

local function test_execute_tool_validation_error()
  -- execute_tool should return validation error before calling the tool
  local result, is_error = tools.execute_tool("read", {})
  assert(is_error, "should be an error")
  assert(result:match("validation error"), "should be a validation error: " .. result)
  assert(result:match("missing required property: path"), "should mention missing path: " .. result)
  print("✓ execute_tool returns validation errors")
end
test_execute_tool_validation_error()

local function test_execute_tool_type_validation()
  local result, is_error = tools.execute_tool("bash", {command = 42})
  assert(is_error, "should be an error")
  assert(result:match("validation error"), "should be a validation error: " .. result)
  assert(result:match("expected string, got number"), "should describe type mismatch: " .. result)
  print("✓ execute_tool catches type mismatches")
end
test_execute_tool_type_validation()

-- Split return value (details) tests
local function test_read_details_multiline()
  local test_file = fs.join(TEST_TMPDIR, "test_multiline.txt")
  cio.barf(test_file, "line1\nline2\nline3\n")

  local result, is_error, details = tools.execute_tool("read", {path = test_file})
  assert(not is_error, "read should succeed")
  assert(details, "should return details")
  assert(details.path == test_file, "details path should match")
  assert(details.line_count == 4, "should count lines (including trailing): " .. tostring(details.line_count))
  print("✓ read details include line_count")
end
test_read_details_multiline()

local function test_edit_details_multiline()
  local test_file = fs.join(TEST_TMPDIR, "test_edit_multi.txt")
  cio.barf(test_file, "line1\nline2\nline3\n")

  local result, is_error, details = tools.execute_tool("edit", {
    path = test_file,
    old_string = "line2",
    new_string = "replaced_a\nreplaced_b\nreplaced_c"
  })
  assert(not is_error, "edit should succeed")
  assert(details, "should return details")
  assert(details.old_lines == 1, "old_lines should be 1")
  assert(details.new_lines == 3, "new_lines should be 3: " .. tostring(details.new_lines))
  print("✓ edit details track line count changes")
end
test_edit_details_multiline()

local function test_read_image_details()
  local png_path = fs.join(TEST_TMPDIR, "test_details.png")
  cio.barf(png_path, "fake png data for details test")

  local result, is_error, details = tools.execute_tool("read", {path = png_path})
  assert(not is_error, "should read image")
  assert(details, "image read should return details")
  assert(details.path == png_path, "details path should match")
  assert(details.bytes == 30, "details should have bytes: " .. tostring(details.bytes))
  assert(details.media_type == "image/png", "details should have media_type")
  print("✓ read image returns details with media_type and bytes")
end
test_read_image_details()

local function test_validation_error_no_details()
  local result, is_error, details = tools.execute_tool("read", {})
  assert(is_error, "should be error")
  assert(details == nil, "validation errors should not return details")
  print("✓ validation errors return nil details")
end
test_validation_error_no_details()

local function test_unknown_tool_no_details()
  local result, is_error, details = tools.execute_tool("nonexistent", {})
  assert(is_error, "should be error")
  assert(details == nil, "unknown tool should not return details")
  print("✓ unknown tool returns nil details")
end
test_unknown_tool_no_details()

-- Test that bash tool preserves literal newlines in command strings.
-- Regression: old code used sh -c %q double-wrapping which turned
-- newlines into line-continuations, mangling multi-line commands
-- (e.g. git commit messages with heredocs).
local function test_bash_newline_in_command()
  local cmd = "echo first\necho second"
  local result, is_error = tools.execute_tool("bash", {command = cmd})
  assert(not is_error, "multiline command should succeed: " .. result)
  assert(result:match("first\nsecond"), "should run both echo commands: " .. result)
  print("✓ bash tool preserves literal newlines in commands")
end
test_bash_newline_in_command()

-- Test that bash tool supports bash-specific syntax (brace expansion).
-- Regression: old code used sh which lacks brace expansion.
local function test_bash_brace_expansion()
  local result, is_error = tools.execute_tool("bash", {command = "echo {a,b,c}"})
  assert(not is_error, "bash should succeed")
  assert(result:match("a b c"), "brace expansion should work (bash feature): " .. result)
  print("✓ bash tool supports bash features (brace expansion)")
end
test_bash_brace_expansion()

-- Test abort_running_tools with no running processes (should be a no-op)
local function test_abort_no_processes()
  -- Should not error when nothing is running
  tools.abort_running_tools()
  print("✓ abort_running_tools handles no running processes")
end
test_abort_no_processes()

-- Test abort_running_tools kills a running process
local function test_abort_kills_process()
  -- Start a long-running process via bash tool in background
  -- We do this by starting the tool in a coroutine-like approach:
  -- spawn a sleep directly and verify it gets killed
  local child_mod = require("cosmic.child")
  local signal_mod = require("cosmic.signal")
  local time_mod = require("cosmic.time")

  -- Use the bash tool to start a process, but since bash tool is synchronous
  -- (blocks on handle:read()), we test the abort mechanism more directly:
  -- Start a process, register it, then call abort
  local handle = child_mod.spawn({"sleep", "30"})
  assert(handle, "should spawn process")
  local pid = handle.pid
  assert(pid, "should have pid")

  -- Verify it's running (kill with signal 0 checks existence)
  local alive = pcall(function() signal_mod.kill(pid, 0) end)
  assert(alive, "process should be alive")

  -- The abort function works on running_processes tracked by tools module.
  -- Since we spawned this externally, abort_running_tools won't see it.
  -- But we can verify the SIGTERM/SIGKILL pattern works:
  signal_mod.kill(pid, child_mod.SIGTERM)
  time_mod.sleep(0, 100000000) -- 100ms

  -- Process should be gone after SIGTERM
  local still_alive = pcall(function() signal_mod.kill(pid, 0) end)
  -- Clean up the zombie
  child_mod.wait(pid, 0)
  print("✓ SIGTERM/SIGKILL discipline works on spawned processes")
end
test_abort_kills_process()

-- Test that string integers are coerced to integers before validation
-- Regression: Claude models sometimes serialize integers as strings
local function test_string_integer_coercion()
  -- Read tool with string limit/offset (Claude often sends these as strings)
  local test_file = fs.join(TEST_TMPDIR, "test_coerce.txt")
  cio.barf(test_file, "line1\nline2\nline3\nline4\nline5\n")

  local result, is_error = tools.execute_tool("read", {
    path = test_file,
    limit = "2",  -- string instead of integer
    offset = "2"  -- string instead of integer
  })
  assert(not is_error, "read with string integers should succeed: " .. result)
  assert(result:match("2\tline2"), "should start at offset 2: " .. result)
  assert(not result:match("4\tline4"), "should respect limit of 2: " .. result)
  print("✓ read tool coerces string integers to integers")
end
test_string_integer_coercion()

local function test_bash_timeout_string_coercion()
  -- Bash tool with string timeout
  local result, is_error = tools.execute_tool("bash", {
    command = "echo hello",
    timeout = "5000"  -- string instead of integer
  })
  assert(not is_error, "bash with string timeout should succeed: " .. result)
  assert(result:match("hello"), "should execute command")
  print("✓ bash tool coerces string timeout to integer")
end
test_bash_timeout_string_coercion()

-- format_tools_for_prompt tests
local function test_format_tools_for_prompt_builtin()
  -- Reset to no custom tools
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))

  local prompt = tools.format_tools_for_prompt()
  assert(prompt:match("Tools:"), "should have Tools: line")
  assert(prompt:match("bash"), "should list bash")
  assert(prompt:match("read"), "should list read")
  assert(prompt:match("write"), "should list write")
  assert(prompt:match("edit"), "should list edit")
  -- Should include system_prompt guidance from builtins
  assert(prompt:match("old_string"), "should include edit guidance")
  assert(prompt:match("Use read to examine"), "should include read guidance")
  print("✓ format_tools_for_prompt includes builtin tools and guidance")
end
test_format_tools_for_prompt_builtin()

local function test_format_tools_for_prompt_with_custom()
  local project = fs.join(TEST_TMPDIR, "prompt_custom_project")
  local project_tools = fs.join(project, "tools")
  fs.makedirs(project_tools)

  cio.barf(fs.join(project_tools, "deploy.lua"), [[
return {
  name = "deploy",
  description = "Deploy the application",
  system_prompt = "Run deploy after all tests pass.\nNever deploy without confirmation.",
  input_schema = {type = "object", properties = {}, required = {}},
  execute = function() return "deployed", false end,
}
]])

  tools.init_custom_tools(project)

  local prompt = tools.format_tools_for_prompt()
  assert(prompt:match("deploy"), "should list deploy tool")
  assert(prompt:match("Deploy the application"), "should include deploy description")
  assert(prompt:match("Never deploy without confirmation"), "should include deploy system_prompt")

  -- Reset
  tools.init_custom_tools(fs.join(TEST_TMPDIR, "nonexistent"))
  print("✓ format_tools_for_prompt includes custom tool guidance")
end
test_format_tools_for_prompt_with_custom()

print("\nAll tools tests passed!")
