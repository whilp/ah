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

skills are loaded from two locations (in order):

1. `/zip/embed/sys/skills/` — built-in skills embedded in the executable.
2. `sys/skills/` — local project skills (for development).

## invocation

users invoke skills explicitly:
- CLI: `ah --skill plan "issue text"`
- prompt prefix: `/skill:plan` in the prompt text.

when invoked, the skill content is prepended to the user prompt.

## system prompt injection

`skills.format_skills_for_prompt()` generates an `<available_skills>` XML
block listing all skill names, descriptions, and file paths. this is
appended to the system prompt so the agent knows what skills exist and
can `read` them when relevant.

## built-in skills

| skill | purpose |
|-------|---------|
| plan | research codebase, write structured work plan |
| do | execute work plan, make changes, run validation |
| check | review changes against plan, render verdict |
| fix | address check feedback, re-validate, commit |
| pr | open pull request, resolve conflicts, watch CI |
| review-pr | review incoming pull request |
| triage-issues | assess priority, deduplicate, label issues |
| workflow | trigger GitHub Actions, debug failures |
| analyze-session | analyze session.db for agent friction |
| setup-work | bootstrap ah work loop in a new repo |
| init | generate agent-friendly documentation |
