-- sys/tools/skill.tl: load a skill by name from available paths
local skills = require("ah.skills")
local tools = require("ah.tools")
local cio = require("cosmic.io")

-- Cache loaded skills (populated on first call)
local loaded_skills: {string:skills.Skill} = nil

return {
  name = "skill",
  description = "Load a skill by name from available paths",
  system_prompt = "Use skill to load a skill's content when the task matches its description. Prefer this over reading skill files directly.",
  input_schema = {
    type = "object",
    properties = {
      name = {type = "string", description = "Skill name to load (e.g. 'init', 'write-skill')"},
    },
    required = {"name"},
  },
  execute = function(input: {string:any}): string, boolean, any
    local name = input.name as string
    if not name or name == "" then
      return "error: name is required", true
    end

    -- Load skills on first use
    if not loaded_skills then
      loaded_skills = skills.load_skills()
    end

    local skill = loaded_skills[name]
    if not skill then
      -- List available skill names for discoverability
      local available: {string} = {}
      for k, _ in pairs(loaded_skills) do
        table.insert(available, k)
      end
      table.sort(available)
      return "error: unknown skill: " .. name .. "\navailable skills: " .. table.concat(available, ", "), true
    end

    -- Read the file content
    local content = cio.slurp(skill.file_path)
    if not content then
      return "error: failed to read skill file: " .. skill.file_path, true
    end

    -- Strip frontmatter
    local body = skills.strip_frontmatter(content)
    body = body:match("^%s*(.-)%s*$") or ""

    -- Count lines
    local line_count = 0
    for _ in body:gmatch("[^\n]*") do
      line_count = line_count + 1
    end

    -- Auto-load tools from the skill's tools/ subdirectory
    tools.load_skill_tools(skill.base_dir)

    return body, false, {
      path = skill.file_path,
      skill_name = skill.name,
      line_count = line_count,
    }
  end,
}
