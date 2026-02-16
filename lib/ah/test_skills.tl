#!/usr/bin/env cosmic
-- test_skills.tl: tests for skill loading and expansion
local skills = require("ah.skills")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/test_skills"
fs.makedirs(tmpdir)

-- Tests for parse_frontmatter
local function test_parse_frontmatter_basic()
  local fields, body = skills.parse_frontmatter("---\nname: my-skill\ndescription: A test skill\n---\n# Body\n")
  assert(fields.name == "my-skill", "expected 'my-skill', got: " .. tostring(fields.name))
  assert(fields.description == "A test skill", "expected 'A test skill', got: " .. tostring(fields.description))
  assert(body == "# Body\n", "expected '# Body\\n', got: " .. tostring(body))
end
test_parse_frontmatter_basic()

local function test_parse_frontmatter_quoted()
  local fields, _ = skills.parse_frontmatter('---\nname: "quoted-name"\ndescription: \'single quoted\'\n---\nbody')
  assert(fields.name == "quoted-name", "expected 'quoted-name', got: " .. tostring(fields.name))
  assert(fields.description == "single quoted", "expected 'single quoted', got: " .. tostring(fields.description))
end
test_parse_frontmatter_quoted()

local function test_parse_frontmatter_none()
  local fields, body = skills.parse_frontmatter("# No frontmatter\nJust body.")
  assert(next(fields) == nil, "expected empty fields")
  assert(body == "# No frontmatter\nJust body.", "expected full content as body")
end
test_parse_frontmatter_none()

local function test_parse_frontmatter_no_closing()
  local content = "---\nname: broken\n# No closing delimiter"
  local fields, body = skills.parse_frontmatter(content)
  assert(next(fields) == nil, "expected empty fields for unclosed frontmatter")
  assert(body == content, "expected full content as body")
end
test_parse_frontmatter_no_closing()

-- Tests for is_valid_name
local function test_valid_names()
  assert(skills.is_valid_name("my-skill") == true, "my-skill should be valid")
  assert(skills.is_valid_name("skill123") == true, "skill123 should be valid")
  assert(skills.is_valid_name("a") == true, "single char should be valid")
end
test_valid_names()

local function test_invalid_names()
  assert(skills.is_valid_name("") == false, "empty should be invalid")
  assert(skills.is_valid_name("My-Skill") == false, "uppercase should be invalid")
  assert(skills.is_valid_name("my_skill") == false, "underscore should be invalid")
  assert(skills.is_valid_name("my skill") == false, "space should be invalid")
  local long = string.rep("a", 65)
  assert(skills.is_valid_name(long) == false, "65 chars should be invalid")
end
test_invalid_names()

-- Tests for strip_frontmatter
local function test_strip_frontmatter()
  local body = skills.strip_frontmatter("---\nname: test\n---\n# Content\nHello")
  assert(body == "# Content\nHello", "expected body without frontmatter, got: " .. body)
end
test_strip_frontmatter()

local function test_strip_no_frontmatter()
  local body = skills.strip_frontmatter("# Content\nHello")
  assert(body == "# Content\nHello", "expected unchanged content, got: " .. body)
end
test_strip_no_frontmatter()

-- Tests for load_skill_from_file
local function test_load_skill_from_file()
  local skill_dir = fs.join(tmpdir, "load-test")
  fs.makedirs(skill_dir)
  local skill_path = fs.join(skill_dir, "test-skill.md")
  cio.barf(skill_path, "---\nname: test-skill\ndescription: A test skill for testing.\n---\n# Test\nDo the thing.")
  local skill = skills.load_skill_from_file(skill_path, skill_dir)
  assert(skill ~= nil, "skill should load")
  assert(skill.name == "test-skill", "name should be test-skill, got: " .. tostring(skill.name))
  assert(skill.description == "A test skill for testing.", "description mismatch")
  assert(skill.file_path == skill_path, "file_path mismatch")
  assert(skill.base_dir == skill_dir, "base_dir mismatch")
end
test_load_skill_from_file()

local function test_load_skill_no_description()
  local skill_dir = fs.join(tmpdir, "no-desc")
  fs.makedirs(skill_dir)
  local skill_path = fs.join(skill_dir, "bad.md")
  cio.barf(skill_path, "---\nname: bad\n---\n# No description")
  local skill = skills.load_skill_from_file(skill_path, skill_dir)
  assert(skill == nil, "skill without description should return nil")
end
test_load_skill_no_description()

local function test_load_skill_derive_name_from_file()
  local skill_dir = fs.join(tmpdir, "derive-name")
  fs.makedirs(skill_dir)
  local skill_path = fs.join(skill_dir, "my-tool.md")
  cio.barf(skill_path, "---\ndescription: Derived name skill.\n---\n# Content")
  local skill = skills.load_skill_from_file(skill_path, skill_dir)
  assert(skill ~= nil, "skill should load")
  assert(skill.name == "my-tool", "name should derive from filename, got: " .. tostring(skill.name))
end
test_load_skill_derive_name_from_file()

local function test_load_skill_derive_name_from_dir()
  local skill_dir = fs.join(tmpdir, "my-skill")
  fs.makedirs(skill_dir)
  local skill_path = fs.join(skill_dir, "SKILL.md")
  cio.barf(skill_path, "---\ndescription: Dir name skill.\n---\n# Content")
  local skill = skills.load_skill_from_file(skill_path, skill_dir)
  assert(skill ~= nil, "skill should load")
  assert(skill.name == "my-skill", "name should derive from dir, got: " .. tostring(skill.name))
end
test_load_skill_derive_name_from_dir()

-- Tests for load_skills_from_dir
local function test_load_skills_from_dir()
  local dir = fs.join(tmpdir, "skills-dir")
  fs.makedirs(dir)

  -- Root-level skill
  cio.barf(fs.join(dir, "root-skill.md"), "---\nname: root-skill\ndescription: A root skill.\n---\n# Root")

  -- Subdirectory skill
  local sub = fs.join(dir, "sub-skill")
  fs.makedirs(sub)
  cio.barf(fs.join(sub, "SKILL.md"), "---\nname: sub-skill\ndescription: A sub skill.\n---\n# Sub")

  local loaded = skills.load_skills_from_dir(dir)
  assert(#loaded >= 2, "expected at least 2 skills, got " .. #loaded)

  local found_root, found_sub = false, false
  for _, s in ipairs(loaded) do
    if s.name == "root-skill" then found_root = true end
    if s.name == "sub-skill" then found_sub = true end
  end
  assert(found_root, "should find root-skill")
  assert(found_sub, "should find sub-skill")
end
test_load_skills_from_dir()

local function test_load_skills_from_dir_empty()
  local dir = fs.join(tmpdir, "empty-skills")
  fs.makedirs(dir)
  local loaded = skills.load_skills_from_dir(dir)
  assert(#loaded == 0, "expected 0 skills from empty dir")
end
test_load_skills_from_dir_empty()

local function test_load_skills_from_dir_nonexistent()
  local loaded = skills.load_skills_from_dir(fs.join(tmpdir, "does-not-exist"))
  assert(#loaded == 0, "expected 0 skills from nonexistent dir")
end
test_load_skills_from_dir_nonexistent()

-- Tests for format_skills_for_prompt
local function test_format_skills_empty()
  local result = skills.format_skills_for_prompt({})
  assert(result == "", "empty skills should produce empty string")
end
test_format_skills_empty()

local function test_format_skills_one()
  local s: {string:skills.Skill} = {
    ["test-skill"] = {
      name = "test-skill",
      description = "A test skill.",
      file_path = "/path/to/test-skill.md",
      base_dir = "/path/to",
    }
  }
  local result = skills.format_skills_for_prompt(s)
  assert(result:find("<available_skills>") ~= nil, "should contain available_skills tag")
  assert(result:find("<name>test%-skill</name>") ~= nil, "should contain skill name")
  assert(result:find("<description>A test skill%.</description>") ~= nil, "should contain description")
  assert(result:find("<location>/path/to/test%-skill%.md</location>") ~= nil, "should contain location")
  assert(result:find("</available_skills>") ~= nil, "should close available_skills tag")
end
test_format_skills_one()

local function test_format_skills_sorted()
  local s: {string:skills.Skill} = {
    ["beta"] = { name = "beta", description = "B skill.", file_path = "/b.md", base_dir = "/" },
    ["alpha"] = { name = "alpha", description = "A skill.", file_path = "/a.md", base_dir = "/" },
  }
  local result = skills.format_skills_for_prompt(s)
  local alpha_pos = result:find("alpha")
  local beta_pos = result:find("beta")
  assert(alpha_pos < beta_pos, "alpha should come before beta")
end
test_format_skills_sorted()

-- Tests for expand_skill
local function test_expand_skill_basic()
  -- Write a skill file for expansion
  local skill_dir = fs.join(tmpdir, "expand-skill")
  fs.makedirs(skill_dir)
  local skill_path = fs.join(skill_dir, "greet.md")
  cio.barf(skill_path, "---\nname: greet\ndescription: Greet someone.\n---\n# Greeting Skill\n\nSay hello politely.")

  local s: {string:skills.Skill} = {
    greet = {
      name = "greet",
      description = "Greet someone.",
      file_path = skill_path,
      base_dir = skill_dir,
    }
  }
  local expanded, was_skill = skills.expand_skill("/skill:greet", s)
  assert(was_skill == true, "should be a skill invocation")
  assert(expanded:find('<skill name="greet"') ~= nil, "should contain skill tag")
  assert(expanded:find("# Greeting Skill") ~= nil, "should contain skill body")
  assert(expanded:find("Say hello politely.") ~= nil, "should contain skill content")
  assert(expanded:find("References are relative to") ~= nil, "should contain base dir reference")
end
test_expand_skill_basic()

local function test_expand_skill_with_args()
  local skill_dir = fs.join(tmpdir, "expand-args")
  fs.makedirs(skill_dir)
  local skill_path = fs.join(skill_dir, "format.md")
  cio.barf(skill_path, "---\nname: format\ndescription: Format code.\n---\nFormat the code.")

  local s: {string:skills.Skill} = {
    format = {
      name = "format",
      description = "Format code.",
      file_path = skill_path,
      base_dir = skill_dir,
    }
  }
  local expanded, was_skill = skills.expand_skill("/skill:format main.py", s)
  assert(was_skill == true, "should be a skill invocation")
  assert(expanded:find("main.py") ~= nil, "should contain user args")
  assert(expanded:find("</skill>") ~= nil, "should close skill tag")
end
test_expand_skill_with_args()

local function test_expand_skill_unknown()
  local expanded, was_skill = skills.expand_skill("/skill:unknown", {})
  assert(was_skill == false, "unknown skill should not expand")
  assert(expanded == "/skill:unknown", "should pass through unchanged")
end
test_expand_skill_unknown()

local function test_expand_skill_not_skill()
  local expanded, was_skill = skills.expand_skill("/command arg", {})
  assert(was_skill == false, "non-skill should not match")
  assert(expanded == "/command arg", "should pass through unchanged")
end
test_expand_skill_not_skill()

local function test_expand_skill_regular_text()
  local expanded, was_skill = skills.expand_skill("just a regular prompt", {})
  assert(was_skill == false, "regular text should not match")
  assert(expanded == "just a regular prompt", "should pass through unchanged")
end
test_expand_skill_regular_text()

-- Tests for project skills (cwd/skills/)
local function test_load_skills_project_override()
  -- Create a fake project with skills/
  local project = fs.join(tmpdir, "project")
  local project_skills_dir = fs.join(project, "skills")
  fs.makedirs(project_skills_dir)

  -- Write a project skill that would override a system skill by name
  cio.barf(fs.join(project_skills_dir, "my-project-skill.md"),
    "---\nname: my-project-skill\ndescription: A project-local skill.\n---\n# Project Skill\nDo project things.")

  local loaded = skills.load_skills(project)

  -- The project skill should be present
  assert(loaded["my-project-skill"] ~= nil, "project skill should be loaded")
  assert(loaded["my-project-skill"].description == "A project-local skill.",
    "project skill description mismatch")
  assert(loaded["my-project-skill"].file_path == fs.join(project_skills_dir, "my-project-skill.md"),
    "project skill file_path should point to project dir")
end
test_load_skills_project_override()

local function test_load_skills_project_no_dir()
  -- A project with no skills/ should still work (just loads system skills)
  local empty_project = fs.join(tmpdir, "empty-project")
  fs.makedirs(empty_project)
  local loaded = skills.load_skills(empty_project)
  -- Should not error; system skills should still be present
  assert(type(loaded) == "table", "should return a table even without project skills dir")
end
test_load_skills_project_no_dir()

local function test_load_skills_project_subdirectory_skill()
  -- Test SKILL.md in a subdirectory under skills/
  local project = fs.join(tmpdir, "project-subdir")
  local sub_skill_dir = fs.join(project, "skills", "custom-tool")
  fs.makedirs(sub_skill_dir)
  cio.barf(fs.join(sub_skill_dir, "SKILL.md"),
    "---\ndescription: A custom tool skill.\n---\n# Custom Tool\nUse the custom tool.")

  local loaded = skills.load_skills(project)
  assert(loaded["custom-tool"] ~= nil, "subdirectory skill should be loaded")
  assert(loaded["custom-tool"].description == "A custom tool skill.",
    "subdirectory skill description mismatch")
  assert(loaded["custom-tool"].base_dir == sub_skill_dir,
    "subdirectory skill base_dir should be the subdirectory")
end
test_load_skills_project_subdirectory_skill()

print("all skills tests passed")
