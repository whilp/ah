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

`tools.init_custom_tools()` loads tool definitions from `tools/` directories
at startup. custom tools are defined as JSON files with an `execute` field
pointing to a script.

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
