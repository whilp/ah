#!/usr/bin/env cosmic
-- test_skill_phases.tl: tests that work phase prompts are valid skills
-- RED phase: these tests should fail before the conversion, pass after.

local skills = require("ah.skills")
local cio = require("cosmic.io")

-- The work phase prompts should be loadable as skills with valid frontmatter.
-- They live in sys/work/ (source) and /zip/embed/sys/work/ (embedded).
-- After conversion, they should live in sys/skills/ and be loadable as skills.

local work_phases = {"plan", "check", "do", "fix", "analyze", "friction"}

-- Test 1: each work phase file has valid frontmatter with name and description
local function test_work_phases_have_frontmatter()
  for _, phase in ipairs(work_phases) do
    -- Try embedded path first, then source path
    local path = "/zip/embed/sys/skills/" .. phase .. ".md"
    local content = cio.slurp(path)
    if not content then
      path = "sys/skills/" .. phase .. ".md"
      content = cio.slurp(path)
    end
    assert(content, "work phase skill file not found: " .. phase .. ".md (tried sys/skills/)")

    local fields, body = skills.parse_frontmatter(content)
    assert(fields.name == phase,
      phase .. ": expected name '" .. phase .. "', got: " .. tostring(fields.name))
    assert(fields.description and #fields.description > 0,
      phase .. ": missing description in frontmatter")
    assert(body and #body > 10,
      phase .. ": body too short after frontmatter")
  end
  print("✓ all work phase files have valid frontmatter")
end
test_work_phases_have_frontmatter()

-- Test 2: each work phase is loadable as a Skill via load_skill_from_file
local function test_work_phases_loadable_as_skills()
  for _, phase in ipairs(work_phases) do
    local path = "/zip/embed/sys/skills/" .. phase .. ".md"
    local base_dir = "/zip/embed/sys/skills"
    local content = cio.slurp(path)
    if not content then
      path = "sys/skills/" .. phase .. ".md"
      base_dir = "sys/skills"
    end
    assert(cio.slurp(path), "file not found: " .. path)

    local skill = skills.load_skill_from_file(path, base_dir)
    assert(skill, phase .. ": failed to load as skill from " .. path)
    assert(skill.name == phase,
      phase .. ": skill name mismatch, got: " .. tostring(skill.name))
    assert(skill.description and #skill.description > 0,
      phase .. ": skill missing description")
  end
  print("✓ all work phase files loadable as skills")
end
test_work_phases_loadable_as_skills()

-- Test 3: work phase skills are discovered by load_skills_from_dir
local function test_work_phases_discovered()
  local dir = "/zip/embed/sys/skills"
  local loaded = skills.load_skills_from_dir(dir)
  if #loaded == 0 then
    dir = "sys/skills"
    loaded = skills.load_skills_from_dir(dir)
  end

  local found: {string:boolean} = {}
  for _, s in ipairs(loaded) do
    found[s.name] = true
  end

  for _, phase in ipairs(work_phases) do
    assert(found[phase],
      phase .. ": not discovered by load_skills_from_dir in " .. dir)
  end
  print("✓ all work phase skills discovered by load_skills_from_dir")
end
test_work_phases_discovered()

-- Test 4: read_prompt returns body WITHOUT frontmatter (interpolation-ready)
local function test_read_prompt_strips_frontmatter()
  local record PromptMod
    read_prompt: function(string): string
  end
  local prompt = require("ah.work.prompt") as PromptMod

  for _, phase in ipairs(work_phases) do
    local content = prompt.read_prompt(phase .. ".md")
    assert(content, phase .. ": read_prompt returned nil")
    -- The returned content should NOT start with ---
    assert(not content:match("^%s*%-%-%-"),
      phase .. ": read_prompt should strip frontmatter, but content starts with ---")
    -- The content should contain the actual prompt body
    assert(#content > 10,
      phase .. ": read_prompt returned too-short content (" .. #content .. " bytes)")
  end
  print("✓ read_prompt strips frontmatter from work phase skills")
end
test_read_prompt_strips_frontmatter()

-- Test 5: plan prompt still has expected template variables after conversion
local function test_plan_prompt_has_template_vars()
  local record PromptMod
    read_prompt: function(string): string
  end
  local prompt = require("ah.work.prompt") as PromptMod

  local plan = prompt.read_prompt("plan.md")
  assert(plan, "plan.md not found")
  assert(plan:find("{title}"), "plan.md should contain {title} template variable")
  assert(plan:find("{body}"), "plan.md should contain {body} template variable")
  assert(plan:find("{issue_number}"), "plan.md should contain {issue_number} template variable")
  print("✓ plan prompt retains template variables")
end
test_plan_prompt_has_template_vars()

-- Test 6: do prompt still has expected template variables
local function test_do_prompt_has_template_vars()
  local record PromptMod
    read_prompt: function(string): string
  end
  local prompt = require("ah.work.prompt") as PromptMod

  local content = prompt.read_prompt("do.md")
  assert(content, "do.md not found")
  assert(content:find("{plan.md contents}"), "do.md should contain {plan.md contents}")
  assert(content:find("{branch}"), "do.md should contain {branch}")
  assert(content:find("{title}"), "do.md should contain {title}")
  print("✓ do prompt retains template variables")
end
test_do_prompt_has_template_vars()

-- Test 7: check prompt still has expected template variables
local function test_check_prompt_has_template_vars()
  local record PromptMod
    read_prompt: function(string): string
  end
  local prompt = require("ah.work.prompt") as PromptMod

  local content = prompt.read_prompt("check.md")
  assert(content, "check.md not found")
  assert(content:find("{plan.md contents}"), "check.md should contain {plan.md contents}")
  assert(content:find("{do.md contents}"), "check.md should contain {do.md contents}")
  print("✓ check prompt retains template variables")
end
test_check_prompt_has_template_vars()

-- Test 8: friction prompt still has expected template variables
local function test_friction_prompt_has_template_vars()
  local record PromptMod
    read_prompt: function(string): string
  end
  local prompt = require("ah.work.prompt") as PromptMod

  local content = prompt.read_prompt("friction.md")
  assert(content, "friction.md not found")
  assert(content:find("{friction_path}"), "friction.md should contain {friction_path}")
  print("✓ friction prompt retains template variables")
end
test_friction_prompt_has_template_vars()

-- Test 9: work phase skills show up in format_skills_for_prompt
local function test_work_phases_in_system_prompt()
  local dir = "/zip/embed/sys/skills"
  local loaded = skills.load_skills_from_dir(dir)
  if #loaded == 0 then
    dir = "sys/skills"
    loaded = skills.load_skills_from_dir(dir)
  end

  -- Convert to map
  local skill_map: {string:skills.Skill} = {}
  for _, s in ipairs(loaded) do
    skill_map[s.name] = s
  end

  local prompt_text = skills.format_skills_for_prompt(skill_map)

  for _, phase in ipairs(work_phases) do
    assert(prompt_text:find("<name>" .. phase .. "</name>"),
      phase .. ": not listed in formatted skills prompt")
  end
  print("✓ work phase skills appear in system prompt skills listing")
end
test_work_phases_in_system_prompt()

-- Test 10: existing triage-issues skill still works alongside new phase skills
local function test_triage_still_discovered()
  local dir = "/zip/embed/sys/skills"
  local loaded = skills.load_skills_from_dir(dir)
  if #loaded == 0 then
    dir = "sys/skills"
    loaded = skills.load_skills_from_dir(dir)
  end

  local found = false
  for _, s in ipairs(loaded) do
    if s.name == "triage-issues" then
      found = true
      break
    end
  end
  assert(found, "triage-issues skill should still be discovered alongside work phase skills")
  print("✓ triage-issues skill still discovered")
end
test_triage_still_discovered()

print("\nAll work phase skill tests passed!")
