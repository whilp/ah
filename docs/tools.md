# tools

source: `lib/ah/tools.tl`, `lib/ah/truncate.tl`

## built-in tools

ah provides four tools to the agent:

### read

reads a file and returns its contents. supports text files and images
(jpg, png, gif, webp — returned as base64 with media type for the API).

parameters:
- `path` (required): file path
- `offset` (optional): line number to start reading (1-indexed, text only)
- `limit` (optional): max lines to read (text only)

binary files are detected (null bytes or >10% non-printable ASCII) and
rejected with an error message.

### write

creates or overwrites a file with the given content. creates parent
directories as needed.

parameters:
- `path` (required): file path
- `content` (required): file content

### edit

finds and replaces text in a file. `old_string` must match exactly one
location in the file (unique match requirement).

parameters:
- `path` (required): file path
- `old_string` (required): text to find (must be unique in file)
- `new_string` (required): replacement text

### bash

executes a shell command. uses `/bin/bash -o pipefail -ec`. has a
configurable timeout (default 120s). returns stdout + stderr combined.

parameters:
- `command` (required): shell command to execute
- `timeout` (optional): timeout in milliseconds

the tool tracks running processes for abort cleanup on ctrl+c.

## custom tools

custom tools extend the agent's capabilities. they are lua modules loaded
from `tools/` directories at startup via `tools.init_custom_tools(cwd)`.

### tool record

each tool is a lua table with these fields:

```lua
{
  name = "mytool",
  description = "Short description for API tool definition",
  system_prompt = "Usage guidance injected into the system prompt.",
  input_schema = {type = "object", properties = {...}, required = {...}},
  execute = function(input) return "result", false end,
}
```

- `name`: tool name (used in API calls)
- `description`: one-line description (shown in tool definition)
- `system_prompt` (optional): guidance text appended to the system prompt
- `input_schema`: JSON schema for tool parameters
- `execute`: function taking input table, returning `(result, is_error)`

### loading tiers

tools load from three directories. later sources override earlier ones by name:

1. `/zip/embed/sys/tools/` — system tools (built into the executable)
2. `/zip/embed/tools/` — embed overlay (zip packaging)
3. `cwd/tools/` — project-local tools

each `.lua` file in the directory should return a tool record table.

### CLI tools

CLI tools (shell executables) load from system and embed tiers only:

1. `/zip/embed/sys/bin/` — system CLI tools
2. `/zip/embed/bin/` — embed overlay

each executable in the directory becomes a tool. a companion `<name>.md`
file provides metadata via yaml frontmatter:

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

### system prompt injection

`tools.format_tools_for_prompt()` generates a tools section for the system
prompt. it includes:

1. a `Tools:` line listing all tool names
2. a `name: description` line for each tool
3. per-tool `## name` sections with `system_prompt` guidance

this is called automatically by `init.tl` and appended to the system prompt
before skills and other context.

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
