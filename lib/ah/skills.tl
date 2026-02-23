-- ah/skills.tl: skill loading and expansion
-- skills are markdown files with yaml frontmatter (name, description).
-- the model sees skill descriptions in the system prompt and can load
-- them with the read tool. users invoke skills explicitly via /skill:name.
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

-- Skill record
local record Skill
  name: string
  description: string
  file_path: string
  base_dir: string
end

-- Parse yaml frontmatter from markdown content.
-- Returns frontmatter fields and body (content after frontmatter).
local function parse_frontmatter(content: string): {string: string}, string
  local fields: {string: string} = {}

  -- Check for opening ---
  if not content:match("^%-%-%-\n") then
    return fields, content
  end

  -- Find closing ---
  local fm_end = content:find("\n%-%-%-\n", 4)
  if not fm_end then
    return fields, content
  end

  local fm_block = content:sub(5, fm_end - 1)
  local body = content:sub(fm_end + 5)

  -- Parse simple key: value lines
  for line in fm_block:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_%-]+):%s*(.+)$")
    if key and value then
      -- Strip surrounding quotes if present
      value = value:match("^[\"'](.+)[\"']$") or value
      fields[key] = value
    end
  end

  return fields, body
end

-- Validate a skill name: lowercase a-z, 0-9, hyphens only, max 64 chars.
local function is_valid_name(name: string): boolean
  if not name or #name == 0 or #name > 64 then
    return false
  end
  return name:match("^[a-z0-9%-]+$") ~= nil
end

-- Load a single skill from a file path.
-- Returns nil if the file is not a valid skill (missing name or description).
local function load_skill_from_file(file_path: string, base_dir: string): Skill
  local content = cio.slurp(file_path)
  if not content then return nil end

  local fields, _ = parse_frontmatter(content)

  local name = fields.name
  if not name then
    -- Derive name from parent directory or filename
    local dir_name = base_dir:match("([^/]+)$")
    local file_name = file_path:match("([^/]+)%.md$")
    if file_path:match("SKILL%.md$") then
      name = dir_name
    else
      name = file_name
    end
  end

  if not name or not is_valid_name(name) then
    return nil
  end

  local description = fields.description
  if not description or #description == 0 then
    return nil
  end

  if #description > 1024 then
    description = description:sub(1, 1024)
  end

  return {
    name = name,
    description = description,
    file_path = file_path,
    base_dir = base_dir,
  }
end

-- Load skills from a directory.
-- Looks for *.md at root and SKILL.md inside subdirectories.
local function load_skills_from_dir(dir: string): {Skill}
  local skills: {Skill} = {}

  local dh = fs.opendir(dir)
  if not dh then return skills end

  while true do
    local name = dh:read()
    if not name then break end
    if name == "." or name == ".." then goto continue end

    local full_path = fs.join(dir, name)

    if name:match("%.md$") then
      -- Root-level .md file
      local skill = load_skill_from_file(full_path, dir)
      if skill then
        table.insert(skills, skill)
      end
    else
      -- Check for SKILL.md in subdirectory
      local skill_path = fs.join(full_path, "SKILL.md")
      local skill_content = cio.slurp(skill_path)
      if skill_content then
        local skill = load_skill_from_file(skill_path, full_path)
        if skill then
          table.insert(skills, skill)
        end
      end
    end

    ::continue::
  end

  dh:close()
  return skills
end

-- Load all skills from system, embed, and project directories.
-- Later sources override earlier ones by name:
--   1. system (built-in)
--   2. embed (zip overlay)
--   3. project (cwd/skills/, cwd/.ah/skills/, cwd/.agents/skills/ — all scanned, later wins)
local function load_skills(cwd?: string): {string: Skill}
  cwd = cwd or fs.getcwd()
  local skills: {string: Skill} = {}

  -- System skills first
  local sys_skills = load_skills_from_dir("/zip/embed/sys/skills")
  for _, skill in ipairs(sys_skills) do
    skills[skill.name] = skill
  end

  -- Embed skills (override system)
  local embed_skills = load_skills_from_dir("/zip/embed/skills")
  for _, skill in ipairs(embed_skills) do
    skills[skill.name] = skill
  end

  -- Project skills (override embed and system): scan all, later wins
  local project_dirs = {
    fs.join(cwd, "skills"),
    fs.join(cwd, ".ah", "skills"),
    fs.join(cwd, ".agents", "skills"),
  }
  for _, dir in ipairs(project_dirs) do
    for _, skill in ipairs(load_skills_from_dir(dir)) do
      skills[skill.name] = skill
    end
  end

  return skills
end

-- Format skills for inclusion in the system prompt.
-- Lists skill names, descriptions, and file paths so the model can
-- use the read tool to load the full content when needed.
local function format_skills_for_prompt(skills: {string: Skill}): string
  -- Collect into sorted list for deterministic output
  local sorted: {Skill} = {}
  for _, skill in pairs(skills) do
    table.insert(sorted, skill)
  end
  if #sorted == 0 then
    return ""
  end
  table.sort(sorted, function(a: Skill, b: Skill): boolean
      return a.name < b.name
    end)

  local parts: {string} = {}
  table.insert(parts, "The following skills provide specialized instructions for specific tasks.")
  table.insert(parts, "Use the read tool to load a skill's file when the task matches its description.")
  table.insert(parts, "When a skill file references a relative path, resolve it against the skill's base directory.")
  table.insert(parts, "")
  table.insert(parts, "<available_skills>")

  for _, skill in ipairs(sorted) do
    table.insert(parts, "  <skill>")
    table.insert(parts, "    <name>" .. skill.name .. "</name>")
    table.insert(parts, "    <description>" .. skill.description .. "</description>")
    table.insert(parts, "    <location>" .. skill.file_path .. "</location>")
    table.insert(parts, "  </skill>")
  end

  table.insert(parts, "</available_skills>")
  return table.concat(parts, "\n")
end

-- Strip frontmatter from content, returning just the body.
local function strip_frontmatter(content: string): string
  local _, body = parse_frontmatter(content)
  return body
end

-- Expand a /skill:name invocation.
-- Returns expanded content and whether it was a skill invocation.
local function expand_skill(prompt: string, skills: {string: Skill}): string, boolean
  if not prompt:match("^/skill:") then
    return prompt, false
  end

  -- Extract skill name
  local skill_name = prompt:match("^/skill:([a-z0-9%-]+)")
  if not skill_name then
    return prompt, false
  end

  local skill = skills[skill_name]
  if not skill then
    return prompt, false
  end

  -- Read and strip frontmatter
  local content = cio.slurp(skill.file_path)
  if not content then
    return prompt, false
  end

  local body = strip_frontmatter(content):match("^%s*(.-)%s*$") or ""

  -- Extract user args (everything after /skill:name)
  local args = prompt:match("^/skill:[a-z0-9%-]+%s+(.*)")

  -- Wrap in <skill> tag
  local skill_block = string.format(
    '<skill name="%s" location="%s">\nReferences are relative to %s.\n\n%s\n</skill>',
    skill.name, skill.file_path, skill.base_dir, body
  )

  if args and args ~= "" then
    return skill_block .. "\n\n" .. args, true
  end
  return skill_block, true
end

return {
  parse_frontmatter = parse_frontmatter,
  is_valid_name = is_valid_name,
  load_skill_from_file = load_skill_from_file,
  load_skills_from_dir = load_skills_from_dir,
  load_skills = load_skills,
  format_skills_for_prompt = format_skills_for_prompt,
  strip_frontmatter = strip_frontmatter,
  expand_skill = expand_skill,
  Skill = Skill,
}
