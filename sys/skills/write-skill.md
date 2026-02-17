---
name: write-skill
description: Write a new ah skill. Covers format, structure, conventions, and placement.
---

# write-skill

Create a new skill for ah. skills are markdown files with YAML frontmatter
that give the agent specialized instructions for a task.

## Usage

```
/skill:write-skill <skill-name> <description of what the skill should do>
```

## Steps

### 1. Choose placement

Decide where the skill belongs:

| location | when to use |
|----------|-------------|
| `sys/skills/<name>.md` | built-in skill, ships with the ah executable |
| `skills/<name>.md` | project-local, simple skill (no tools) |
| `skills/<name>/SKILL.md` | project-local, skill with bundled tools |

project-local skills override built-in skills of the same name.

### 2. Choose a name

- lowercase alphanumeric with hyphens only (`[a-z0-9-]+`)
- max 64 characters
- descriptive and specific: `analyze-session`, not `analyze`
- use hyphens to separate words: `write-skill`, not `writeskill`

### 3. Write frontmatter

Every skill starts with YAML frontmatter:

```yaml
---
name: my-skill
description: One-line description of what the skill does.
---
```

the description appears in the `<available_skills>` block in the system
prompt. it must be concise enough to help the agent decide whether to load
the skill.

### 4. Write the body

Use this section order. omit sections that don't apply.

```markdown
# skill-name

Brief intro paragraph. one or two sentences explaining what this skill does
and when to use it.

## Usage

how to invoke the skill, with example arguments.

## Steps

### 1. First step
explanation and commands.

### 2. Second step
...

## Output

what the skill produces. specify filenames, format, and structure.

## Rules

constraints, forbidden actions, edge cases.
```

#### Section guidance

- **intro**: one or two sentences. state what the skill does, not what it is.
- **Usage**: show the `/skill:name` invocation with any expected arguments.
- **Steps**: numbered, sequential. each step has a clear action.
  use fenced bash blocks for commands. commands must be copy-pasteable.
  include expected output or success criteria where helpful.
- **Output**: exact file paths, format templates, or structured output.
  use indented code blocks to show the expected shape.
- **Rules**: short bullet list. what to do, what not to do, priorities.

### 5. Add tool files (if needed)

If the skill needs custom tools, use the subdirectory layout:

```
skills/
  my-skill/
    SKILL.md
    tools/
      my-tool.tl    ← loaded automatically when skill is invoked
```

tool files are `.tl` (teal) modules that export a table with `name`,
`description`, `input_schema`, and `execute` fields. every tool file must
have a corresponding `test_*.tl` file in the same directory.

### 6. Validate

```bash
# check frontmatter parses correctly
head -5 <skill-file>

# if the skill is in a project with CI:
make ci
```

## Conventions

- **short declarative sentences.** no filler, no preamble.
- **concrete over abstract.** file paths, exact commands, specific examples.
- **bash blocks must be copy-pasteable.** test them if unsure.
- **match the project voice.** if the codebase uses lowercase, write lowercase.
- **keep it scannable.** agents skim. use headings, bullets, and code blocks.
  avoid long prose paragraphs.
- **one skill per task.** don't combine unrelated tasks into one skill.
  a skill should have a single clear purpose.
- **idempotent steps.** where possible, steps should be safe to re-run.
- **specify output format exactly.** agents need unambiguous structure to
  produce consistent results.

## When to use skills vs inline instructions

Use a skill when:
- the task is repeatable (not a one-off)
- the steps are specific enough to codify
- multiple people or agents will perform the same task
- consistency matters (output format, validation steps)

Use inline instructions when:
- the task is unique or exploratory
- the steps depend heavily on context not available to the skill
- the skill would be trivially short (1-2 sentences)

## Rules

- every skill must have valid YAML frontmatter with `name` and `description`
- the `name` in frontmatter must match the filename (without `.md` extension)
- do not create skills that duplicate existing ones — check `sys/skills/`
  and the project `skills/` directory first
- keep skills under 200 lines. if longer, the skill is probably doing too much
- do not hardcode paths or values that vary between projects
