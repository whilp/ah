#!/usr/bin/env cosmic
-- test_skill_tool.tl: tests for the skill tool
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local tools = require("ah.tools")
local loop = require("ah.loop")
local json = require("cosmic.json")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/test_skill_tool"
fs.makedirs(tmpdir)

-- Set up a project with skills in the actual cwd
local cwd = fs.getcwd()

-- Use a unique name to avoid conflicts
local test_skill_name = "zz-test-skill-tool"

-- Create test skill in skills/ (project tier)
local skills_dir = fs.join(cwd, "skills")
local dot_ah_skills = fs.join(cwd, ".ah", "skills")
local test_skill_file: string
local dh = fs.opendir(dot_ah_skills)
if dh then
  dh:close()
  test_skill_file = fs.join(dot_ah_skills, test_skill_name .. ".md")
else
  fs.makedirs(skills_dir)
  test_skill_file = fs.join(skills_dir, test_skill_name .. ".md")
end

cio.barf(test_skill_file,
  "---\nname: " .. test_skill_name .. "\ndescription: A test skill for the skill tool test.\n---\n# Test Skill\n\nDo the thing.\nLine two.\nLine three.")

local function cleanup()
  os.remove(test_skill_file)
end

-- Initialize tools from the cwd
tools.init_custom_tools(cwd)

-- Verify the skill tool is loaded
local function test_skill_tool_loaded()
  local defs = tools.get_tool_definitions()
  local found = false
  for _, d in ipairs(defs) do
    if d.name == "skill" then
      found = true
      break
    end
  end
  assert(found, "skill tool should be loaded")
  print("PASS: skill tool loaded")
end
test_skill_tool_loaded()

-- Test loading a known skill: output is just the body
local function test_load_skill()
  local result, is_error, details = tools.execute_tool("skill", {name = test_skill_name})
  assert(not is_error, "should not error: " .. tostring(result))
  -- Body content only (no metadata header)
  assert(result:find("# Test Skill") ~= nil, "should contain skill body")
  assert(result:find("Do the thing.") ~= nil, "should contain skill content")
  assert(result:find("skill:") == nil, "should NOT contain metadata header")
  assert(result:find("source:") == nil, "should NOT contain source line")
  -- Details carry metadata
  assert(details ~= nil, "should return details")
  assert(details.path ~= nil, "details should have path")
  assert(details.skill_name == test_skill_name, "details should have skill_name")
  assert(details.line_count ~= nil, "details should have line_count")
  assert(details.line_count > 0, "line_count should be positive")
  print("PASS: load skill")
end
test_load_skill()

-- Test tool_key_param formats skill display correctly
local function test_key_param_format()
  local details_json = json.encode({
    path = "/zip/embed/sys/skills/init.md",
    skill_name = "init",
    line_count = 42,
  })
  local key = loop.tool_key_param("skill", "{}", details_json)
  assert(key:find("init") ~= nil, "key should contain skill name: " .. key)
  assert(key:find("42 lines") ~= nil, "key should contain line count: " .. key)
  assert(key:find("→") ~= nil, "key should contain arrow: " .. key)
  print("PASS: key param format")
end
test_key_param_format()

-- Test loading an unknown skill
local function test_unknown_skill()
  local result, is_error = tools.execute_tool("skill", {name = "nonexistent-zz-does-not-exist"})
  assert(is_error, "should error for unknown skill")
  assert(result:find("unknown skill") ~= nil, "should mention unknown skill")
  assert(result:find("available skills") ~= nil, "should list available skills")
  print("PASS: unknown skill")
end
test_unknown_skill()

-- Test missing name parameter
local function test_missing_name()
  local result, is_error = tools.execute_tool("skill", {})
  assert(is_error, "should error for missing name")
  print("PASS: missing name")
end
test_missing_name()

-- Test empty name parameter
local function test_empty_name()
  local result, is_error = tools.execute_tool("skill", {name = ""})
  assert(is_error, "should error for empty name")
  print("PASS: empty name")
end
test_empty_name()

cleanup()

-- Test load_skill_tools: loading a skill with tools/ subdirectory auto-loads its tools
local function test_load_skill_tools()
  -- Create a test skill with a tools/ subdirectory
  local skill_dir = fs.join(tmpdir, "test-skill-with-tools")
  local tools_dir_path = fs.join(skill_dir, "tools")
  fs.makedirs(tools_dir_path)

  cio.barf(fs.join(skill_dir, "SKILL.md"),
    "---\nname: zz-test-with-tools\ndescription: A test skill with tools.\n---\n# Test\n\nHas tools.")

  -- Create a simple .lua tool in the tools/ subdirectory
  cio.barf(fs.join(tools_dir_path, "zz-test-skill-tool-auto.lua"), [[
return {
  name = "zz-test-skill-tool-auto",
  description = "Auto-loaded test tool",
  input_schema = {type = "object", properties = {}},
  execute = function(input) return "ok", false end,
}
]])

  -- Initialize tools (standard tiers only)
  tools.init_custom_tools(cwd)

  -- Verify tool is NOT loaded yet
  local defs_before = tools.get_tool_definitions()
  local found_before = false
  for _, d in ipairs(defs_before) do
    if d.name == "zz-test-skill-tool-auto" then
      found_before = true
      break
    end
  end
  assert(not found_before, "skill tool should NOT be loaded before load_skill_tools")

  -- Load skill tools
  tools.load_skill_tools(skill_dir)

  -- Verify tool IS loaded now
  local defs_after = tools.get_tool_definitions()
  local found_after = false
  for _, d in ipairs(defs_after) do
    if d.name == "zz-test-skill-tool-auto" then
      found_after = true
      break
    end
  end
  assert(found_after, "skill tool should be loaded after load_skill_tools")

  -- Verify the tool is functional
  local result, is_error = tools.execute_tool("zz-test-skill-tool-auto", {})
  assert(not is_error, "skill tool should execute without error")
  assert(result == "ok", "skill tool should return 'ok'")

  -- Cleanup
  os.remove(fs.join(tools_dir_path, "zz-test-skill-tool-auto.lua"))
  os.remove(fs.join(skill_dir, "SKILL.md"))
  fs.rmdir(tools_dir_path)
  fs.rmdir(skill_dir)

  print("PASS: load_skill_tools auto-loads tools")
end
test_load_skill_tools()

-- Test load_skill_tools with no tools/ directory is a no-op
local function test_load_skill_tools_no_dir()
  tools.init_custom_tools(cwd)
  local count_before = #tools.get_tool_definitions()

  -- Call with a directory that has no tools/ subdirectory
  tools.load_skill_tools(tmpdir)

  local count_after = #tools.get_tool_definitions()
  assert(count_before == count_after, "tool count should not change when no tools/ dir exists")
  print("PASS: load_skill_tools no-op without tools/ dir")
end
test_load_skill_tools_no_dir()

-- Test that skill tool invocation auto-loads tools
local function test_skill_tool_auto_loads()
  -- Create a test skill with tools in the project skills dir
  local skill_name_auto = "zz-test-auto-load"
  local skill_dir_auto: string
  local skill_tools_dir_auto: string
  local dh2 = fs.opendir(dot_ah_skills)
  if dh2 then
    dh2:close()
    skill_dir_auto = fs.join(dot_ah_skills, skill_name_auto)
  else
    skill_dir_auto = fs.join(skills_dir, skill_name_auto)
  end
  skill_tools_dir_auto = fs.join(skill_dir_auto, "tools")
  fs.makedirs(skill_tools_dir_auto)

  cio.barf(fs.join(skill_dir_auto, "SKILL.md"),
    "---\nname: " .. skill_name_auto .. "\ndescription: Test auto load.\n---\n# Auto\n\nTest.")

  cio.barf(fs.join(skill_tools_dir_auto, "zz-auto-tool.lua"), [[
return {
  name = "zz-auto-tool",
  description = "Auto-loaded via skill tool",
  input_schema = {type = "object", properties = {}},
  execute = function(input) return "auto-ok", false end,
}
]])

  -- Re-initialize tools
  tools.init_custom_tools(cwd)

  -- Verify tool NOT loaded yet
  local found = false
  for _, d in ipairs(tools.get_tool_definitions()) do
    if d.name == "zz-auto-tool" then found = true; break end
  end
  assert(not found, "zz-auto-tool should not be loaded before skill tool invocation")

  -- Invoke the skill tool — this should auto-load skill tools
  local result, is_error = tools.execute_tool("skill", {name = skill_name_auto})
  assert(not is_error, "skill tool should succeed: " .. tostring(result))

  -- Verify tool IS loaded now
  found = false
  for _, d in ipairs(tools.get_tool_definitions()) do
    if d.name == "zz-auto-tool" then found = true; break end
  end
  assert(found, "zz-auto-tool should be loaded after skill tool invocation")

  -- Cleanup
  os.remove(fs.join(skill_tools_dir_auto, "zz-auto-tool.lua"))
  os.remove(fs.join(skill_dir_auto, "SKILL.md"))
  fs.rmdir(skill_tools_dir_auto)
  fs.rmdir(skill_dir_auto)

  print("PASS: skill tool invocation auto-loads tools")
end
test_skill_tool_auto_loads()

print("all skill tool tests passed")
