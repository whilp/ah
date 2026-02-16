# tools

source: `lib/ah/tools.tl`, `sys/tools/`, `lib/ah/truncate.tl`

## built-in tools

ah provides four tools to the agent, defined in `sys/tools/`:

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

executes a shell command. uses `/bin/bash -o pipefail -ec`. has a
configurable timeout (default 120s). returns stdout + stderr combined.

parameters:
- `command` (required): shell command to execute
- `timeout` (optional): timeout in milliseconds

the tool tracks running processes via `running_processes` for abort
cleanup on ctrl+c. `tools.abort_running_tools()` finds this table by
iterating loaded tools.

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
`tools.init_custom_tools(cwd)`, plus a CLI tier. later tiers override
earlier ones by name:

1. **system** (`/zip/embed/sys/tools/`) — built-in tools (read, write,
   edit, bash). compiled from `sys/tools/*.tl` at build time. in dev/test,
   falls back to `o/sys/tools/`.
2. **embed** (`/zip/embed/tools/`) — overlay for custom ah distributions.
3. **project** (`cwd/tools/`) — project-local tools.
4. **CLI** (`--tool name=cmd`) — highest precedence, overrides everything.

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

### overriding core tools

projects can override any core tool by placing a file with the same name
in `cwd/tools/`. for example, `tools/read.lua` replaces the builtin read
tool entirely — schema, description, system_prompt, and execute function
all come from the override.

the system prompt reflects the active tool, so the agent always sees the
overrider's description and guidance.

embed overlays can similarly override system tools for custom ah
distributions. projects then override both.

**caveats:**
- accidental shadowing is possible. a file named `tools/bash` (even if
  unrelated to ah) would replace the builtin bash tool.
- if a bash override omits `running_processes`, ctrl+c abort won't kill
  its running commands. the override owns the behavior.
- the override is total — there is no way to "extend" a core tool; you
  replace it.

### executable tools

any executable file in `cwd/tools/` (without a `.tl` or `.lua` extension)
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

executable tools accept an `args` string parameter which is split on
whitespace and passed as command-line arguments.

### CLI tool overrides (`--tool/-t`)

the `--tool` (`-t`) flag registers a CLI tool from the command line with
highest precedence — it overrides system, embed, and project tools:

```sh
ah --tool deploy=/usr/local/bin/deploy 'deploy the app'
ah -t lint=./tools/lint -t fmt=./tools/fmt 'fix lint errors'
```

format: `--tool name=cmd`. repeatable. the `cmd` is an executable path.
a companion `<cmd>.md` file is read for description (frontmatter) and
system_prompt (body), same as project executable tools.

CLI overrides are applied after `init_custom_tools()`, so they replace
any tool with the same name regardless of tier.

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
