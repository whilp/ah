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
    path = "/zip/embed/sys/skills/plan.md",
    skill_name = "plan",
    line_count = 42,
  })
  local key = loop.tool_key_param("skill", "{}", details_json)
  assert(key:find("plan") ~= nil, "key should contain skill name: " .. key)
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
print("all skill tool tests passed")
