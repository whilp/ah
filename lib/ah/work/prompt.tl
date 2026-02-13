-- ah/work/prompt.tl: prompt loading, interpolation, and building
local cio = require("cosmic.io")
local skills = require("ah.skills")
local util = require("ah.work.util")

-- Read a work phase prompt by name (e.g. "plan.md").
-- Looks in skills dirs first (with frontmatter stripping), then falls back
-- to the legacy sys/work/ location for backward compatibility.
local function read_prompt(name: string): string
  -- Try skills directories first (new location)
  local content = cio.slurp("/zip/embed/sys/skills/" .. name)
                or cio.slurp("sys/skills/" .. name)
  if content then
    return skills.strip_frontmatter(content)
  end
  -- Fallback to legacy location
  return cio.slurp("/zip/embed/sys/work/" .. name)
      or cio.slurp("sys/work/" .. name)
end

local function read_prompt_template(name: string): string
  return cio.slurp("/zip/embed/sys/work/prompts/" .. name .. ".md")
      or cio.slurp("sys/work/prompts/" .. name .. ".md")
end

-- Interpolate template variables safely.
-- Uses function replacement to avoid gsub interpreting % in values as capture references.
local function interpolate_prompt(template: string, vars: {string:string}): string
  for key, value in pairs(vars) do
    template = template:gsub("{" .. key .. "}", function(): string return value end)
  end
  return template
end

-- Diagnostic: inspect plan directory and report what was (or wasn't) created.
-- Returns a human-readable message explaining why plan.md may be missing.
local function plan_diagnostic(plan_dir: string): string
  local parts: {string} = {}

  local plan = util.read_file(plan_dir .. "/plan.md")
  if plan then
    table.insert(parts, "plan.md found (" .. #plan .. " bytes)")
    return table.concat(parts, "; ")
  end

  table.insert(parts, "plan.md not found")

  local update = util.read_file(plan_dir .. "/update.md")
  if update then
    table.insert(parts, "update.md found (bail condition): " .. update:sub(1, 200))
  end

  local issue = util.read_file(plan_dir .. "/issue.json")
  if issue then
    table.insert(parts, "issue.json present")
  else
    table.insert(parts, "issue.json missing")
  end

  return table.concat(parts, "; ")
end

-- Prompt building for do/check/fix phases
-- Extracted for testability.

local function build_do_prompt(template: string, title: string, plan_contents: string, branch: string): string
  return interpolate_prompt(template, {
    title = title,
    ["plan.md contents"] = plan_contents,
    branch = branch,
  })
end

local function build_check_prompt(template: string, plan_contents: string, do_contents: string): string
  return interpolate_prompt(template, {
    ["plan.md contents"] = plan_contents,
    ["do.md contents"] = do_contents,
  })
end

local function build_fix_prompt(template: string, title: string, plan_contents: string, check_contents: string, branch: string): string
  return interpolate_prompt(template, {
    title = title,
    ["plan.md contents"] = plan_contents,
    ["check.md contents"] = check_contents,
    branch = branch,
  })
end

local function build_friction_prompt(template: string, friction_path: string): string
  return interpolate_prompt(template, {
    friction_path = friction_path,
  })
end

-- Build friction follow-up prompt for a given phase output directory.
local function make_friction_prompt(phase_dir: string): string
  local template = read_prompt("friction.md")
  if not template then return nil end
  return build_friction_prompt(template, phase_dir .. "/friction.md")
end

return {
  read_prompt = read_prompt,
  read_prompt_template = read_prompt_template,
  interpolate_prompt = interpolate_prompt,
  plan_diagnostic = plan_diagnostic,
  build_do_prompt = build_do_prompt,
  build_check_prompt = build_check_prompt,
  build_fix_prompt = build_fix_prompt,
  build_friction_prompt = build_friction_prompt,
  make_friction_prompt = make_friction_prompt,
}
