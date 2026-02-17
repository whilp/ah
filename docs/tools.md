# tools

source: `lib/ah/tools.tl`, `sys/tools/`, `lib/ah/truncate.tl`

## built-in tools

ah provides five tools to the agent, defined in `sys/tools/`:

### read (`sys/tools/read.tl`)

reads a file and returns its contents. supports text files and images
(jpg, png, gif, webp — returned as base64 with media type for the API).

parameters:
- `path` (required): file path
- `offset` (optional): line number to start reading (1-indexed, text only)
- `limit` (optional): max lines to read (text only)

binary files are detected (null bytes or >10% non-printable ASCII) and
rejected with an error message.

### write (`sys/tools/write.tl`)

creates or overwrites a file with the given content. creates parent
directories as needed.

parameters:
- `path` (required): file path
- `content` (required): file content

### edit (`sys/tools/edit.tl`)

finds and replaces text in a file. `old_string` must match exactly one
location in the file (unique match requirement).

parameters:
- `path` (required): file path
- `old_string` (required): text to find (must be unique in file)
- `new_string` (required): replacement text

### bash (`sys/tools/bash.tl`)

executes a shell command. uses `bash -c` (or `$AH_SHELL -c`). has a
configurable timeout (default 120s). returns stdout + stderr combined.

parameters:
- `command` (required): shell command to execute
- `timeout` (optional): timeout in milliseconds

the tool tracks running processes via `running_processes` for abort
cleanup on ctrl+c. `tools.abort_running_tools()` finds this table by
iterating loaded tools.

### skill (`sys/tools/skill.tl`)

loads a skill by name from the available skill paths (system → embed →
project). returns the skill body (frontmatter stripped) with a metadata
header showing the source path, base directory, and line count. on
error, lists available skill names for discoverability.

parameters:
- `name` (required): skill name (e.g. `plan`, `do`, `check`)

the tool caches the loaded skills map on first invocation. details
returned include `path` and `line_count`.

## tool format

tools are defined as lua or teal modules that return a table:

```lua
{
  name = "mytool",
  description = "Short description for API tool definition",
  system_prompt = "Usage guidance injected into the system prompt.",
  input_schema = {type = "object", properties = {...}, required = {...}},
  execute = function(input) return "result", false end,
}
```

- `name`: tool name (used in API calls and override matching)
- `description`: one-line description (shown in tool definition)
- `system_prompt` (optional): guidance text appended to the system prompt
- `input_schema`: JSON schema for tool parameters
- `execute`: function taking input table, returning `(result, is_error, details)`
- `running_processes` (optional): `{pid: handle}` table for abort cleanup

## loading

### tiers

tools load from three directory tiers at startup via
`tools.init_custom_tools(cwd)`, plus skill and CLI tiers. later tiers
override earlier ones by name:

1. **system** (`/zip/embed/sys/tools/`) — built-in tools (read, write,
   edit, bash). compiled from `sys/tools/*.tl` at build time. in dev/test,
   falls back to `o/sys/tools/`.
2. **embed** (`/zip/embed/tools/`) — overlay for custom ah distributions.
3. **project** (`cwd/.ah/tools/` or `cwd/tools/`) — project-local tools.
   `.ah/tools/` takes precedence if it exists; otherwise `tools/` is used.
4. **skill** (`<skill-base-dir>/tools/`) — tools bundled with the active
   skill. loaded automatically when a skill is invoked via `--skill`,
   `/skill:name`, or the `skill` tool at runtime.
5. **CLI** (`--tool name=cmd`) — highest precedence, overrides everything.

### file type precedence

within a single directory, when multiple files share a basename:

1. **`.tl`** — teal source, compiled at runtime via `tl.load()`
2. **`.lua`** — lua module, loaded via `loadfile()`
3. **executable** — any file with +x, wrapped as a CLI tool

higher-priority formats win. for example, if `tools/` contains both
`foo.tl` and `foo.lua`, the `.tl` version is used.

embedded tiers (system, embed) only contain `.lua` files since
`sys/tools/*.tl` is pre-compiled by the Makefile. `.tl` runtime loading
is primarily useful at the project tier.

### sibling module requires

tools can `require()` sibling lua or teal modules from the same directory.
when tools are loaded from a directory, that directory is added to
`package.path`. the teal package searcher automatically finds `.tl` files
using the same paths, so both `require("helper")` for `helper.lua` and
`require("helper")` for `helper.tl` work.

sibling modules that are not valid tools (i.e. don't return a table with
name, description, input_schema, execute) are skipped during tool loading
but remain available via `require()`.

this also works for tools loaded via `--tool name=path.lua` or
`--tool name=path.tl` — the file's parent directory is added to
`package.path`.

### overriding core tools

projects can override any core tool by placing a file with the same name
in `cwd/.ah/tools/` or `cwd/tools/`. for example, `.ah/tools/read.lua`
replaces the builtin read tool entirely — schema, description, system_prompt, and execute function
all come from the override.

the system prompt reflects the active tool, so the agent always sees the
overrider's description and guidance.

embed overlays can similarly override system tools for custom ah
distributions. projects then override both.

**caveats:**
- accidental shadowing is possible. a file named `.ah/tools/bash` or
  `tools/bash` (even if unrelated to ah) would replace the builtin
  bash tool.
  using `.ah/tools/` reduces this risk since the directory is explicitly for ah.
- if a bash override omits `running_processes`, ctrl+c abort won't kill
  its running commands. the override owns the behavior.
- the override is total — there is no way to "extend" a core tool; you
  replace it.

### executable tools

any executable file in `cwd/.ah/tools/` or `cwd/tools/` (without a `.tl` or `.lua` extension)
becomes a CLI tool. a companion `<name>.md` file provides metadata via
yaml frontmatter:

```markdown
---
description: Deploy the application
---

Run deploy only after all tests pass.
Never deploy without user confirmation.
```

- `description` frontmatter field → tool description
- body after frontmatter → `system_prompt` guidance
- if no `.md` file exists, falls back to `--help` output for description

executable tools accept an `args` string parameter. the args string
is passed to `bash -c` (or `$AH_SHELL -c`) along with the tool path,
so shell features like quoting, pipes, and globs work normally.

### CLI tool overrides (`--tool/-t`)

the `--tool` (`-t`) flag registers or removes tools from the command
line with highest precedence:

```sh
# add tools (executables)
ah --tool deploy=/usr/local/bin/deploy 'deploy the app'
ah -t lint=./tools/lint -t fmt=./tools/fmt 'fix lint errors'

# add tools (.tl or .lua module files)
ah -t gh=skills/triage/tools/gh.tl 'triage issues'
ah -t mytool=./tools/custom.lua 'use custom tool'

# remove a tool (empty cmd after =)
ah --tool bash= 'explain this codebase'
ah -t bash= -t write= -t edit= 'review the code read-only'
```

format: `--tool name=cmd` adds or replaces a tool. `--tool name=`
(empty cmd) removes it entirely — the tool disappears from the API
tool list and the system prompt. repeatable.

when adding, `cmd` can be:
- a **`.tl` or `.lua` file** — loaded as a module tool (same format as
  project tools: must return a table with name, description, input_schema,
  execute). the name from `--tool` overrides the module's internal name.
- an **executable path** — wrapped as a CLI tool. a companion `<cmd>.md`
  file is read for description (frontmatter) and system_prompt (body).

CLI overrides are applied after `init_custom_tools()`, so they replace
or remove any tool regardless of tier.

## system prompt injection

`tools.format_tools_for_prompt()` generates a tools section for the system
prompt. it includes:

1. a `Tools:` line listing all tool names (sorted)
2. a `name: description` line for each tool
3. per-tool `## name` sections with `system_prompt` guidance

this is called automatically by `init.tl` and appended to the system prompt
after the base prompt and before skills.

## truncation

`truncate.tl` truncates tool output before sending to the API while
preserving full output in the database.

strategy: two-pass head/tail split.
1. **character truncation**: keeps first and last `max_chars/2` bytes,
   removes the middle.
2. **line truncation**: keeps first and last `max_lines/2` lines (bash only).

default limits:

| tool | char limit | line limit |
|------|-----------|------------|
| bash | 30,000 | 256 |
| read | 50,000 | — |
| write | 10,000 | — |
| edit | 10,000 | — |

## protected directories

`AH_PROTECT_DIRS` (colon-separated paths) prevents write/edit operations
to specified directories. the write and edit tools check this before
executing.
