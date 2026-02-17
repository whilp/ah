# skills

source: `lib/ah/skills.tl`, `sys/skills/`

## what skills are

skills are markdown files with YAML frontmatter that provide specialized
instructions for specific tasks. the agent sees skill names and descriptions
in the system prompt and can load skill content with the `read` tool.

## format

```markdown
---
name: skill-name
description: one-line description of what the skill does
---

skill instructions here...
```

name must be lowercase alphanumeric with hyphens, max 64 chars.

## loading

skills are loaded from three locations (in order). later sources override
earlier ones by name:

1. `/zip/embed/sys/skills/` — built-in skills embedded in the executable.
2. `/zip/embed/skills/` — embed overlay (zip packaging).
3. `cwd/.ah/skills/` or `cwd/skills/` — project-local skills.
   `.ah/skills/` takes precedence if it exists; otherwise `skills/` is used.

project skills let repositories ship custom skills that override or extend
built-in ones. place `.md` files directly in the skills directory or use
subdirectories with `SKILL.md` files. using `.ah/skills/` avoids conflicts
with unrelated `skills/` directories in the project.

## skill tool directories

skills can bundle tools by placing `.tl` or `.lua` tool files in a
`tools/` subdirectory alongside `SKILL.md`. these tools are loaded
automatically when the skill is invoked (via `--skill`, `/skill:name`,
or the `skill` tool at runtime):

```
skills/
  my-skill/
    SKILL.md
    tools/
      gh.tl        ← loaded automatically when my-skill is invoked
```

skill tools load between the project tier and `--tool` CLI overrides,
so `--tool` still has highest precedence. a skill tool can shadow a
project tool by name, and `--tool name=` can remove a skill tool.

```bash
# skill tools load automatically:
ah --skill my-skill 'do the thing'

# --tool can still override or remove skill tools:
ah --skill my-skill -t gh= 'do the thing without gh'
```

## invocation

users invoke skills explicitly:
- CLI: `ah --skill plan "issue text"`
- prompt prefix: `/skill:plan` in the prompt text.

when invoked, the skill content is prepended to the user prompt.

## system prompt injection

`skills.format_skills_for_prompt()` generates an `<available_skills>` XML
block listing all skill names, descriptions, and file paths. this is
appended to the system prompt so the agent knows what skills exist and
can load them when relevant.

## skill tool

the built-in `skill` tool (`sys/tools/skill.tl`) loads a skill by name.
the agent can call `skill(name="plan")` instead of reading the skill file
directly. the tool returns the skill body (frontmatter stripped) with a
metadata header showing source path, base directory, and line count.

## built-in skills

| skill | purpose |
|-------|---------|
| plan | research codebase, write structured work plan |
| do | execute work plan, make changes, run validation |
| check | review changes against plan, render verdict |
| fix | address check feedback, re-validate, commit |
| analyze-session | analyze session.db for agent friction |
| init | generate agent-friendly documentation |
| write-skill | write a new ah skill with correct format and conventions |
