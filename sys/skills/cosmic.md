---
name: cosmic
description: Use cosmic (embedded lua runtime) for scripting: JSON, SQLite, HTTP, filesystem, subprocess, and sandbox tasks.
---

# cosmic

cosmic is the lua runtime embedded in `ah`. use it for scripting tasks: parsing
JSON, querying SQLite, HTTP requests, file manipulation, subprocess management,
and sandboxing.

## Running cosmic scripts

`$AH_COSMIC` is always set to the cosmic binary path inside sandboxed sessions.
use it to run scripts:

```bash
# run a lua script
$AH_COSMIC script.lua

# run inline lua
$AH_COSMIC -e 'print(require("cosmic.json").encode({a=1}))'
```

for shebang scripts, use `$AH_COSMIC` directly instead of `#!/usr/bin/env cosmic`
since `cosmic` may not be on PATH:

```bash
$AH_COSMIC script.lua arg1 arg2
```

or write scripts without shebangs and invoke explicitly.

## Key modules

| module | purpose |
|--------|---------|
| `cosmic.json` | JSON encode/decode |
| `cosmic.fs` | filesystem: read, write, stat, makedirs, glob, getcwd |
| `cosmic.io` | slurp/barf (read/write entire files as strings) |
| `cosmic.child` | subprocess: spawn, fork, wait, execve |
| `cosmic.fetch` | HTTP/HTTPS requests |
| `cosmic.sqlite` | SQLite database access |
| `cosmic.env` | environment variable helpers |
| `cosmic.sandbox` | unveil/pledge sandbox primitives |
| `cosmic.time` | sleep, timestamps |
| `cosmic.tty` | terminal detection |
| `cosmic.signal` | signal handling |

## Common patterns

### JSON

```lua
local json = require("cosmic.json")
local data = json.decode('{"key": "value"}')
print(json.encode(data))
```

### Filesystem

```lua
local fs = require("cosmic.fs")
local io_mod = require("cosmic.io")

-- read a file
local content = io_mod.slurp("path/to/file")

-- write a file
io_mod.barf("path/to/file", "content\n")

-- list directory
for _, entry in ipairs(fs.readdir(".")) do
  print(entry)
end

-- create directories
fs.makedirs("path/to/dir")
```

### Subprocess

```lua
local child = require("cosmic.child")
local handle, err = child.spawn({"/usr/bin/git", "status"})
assert(handle, err)
local ok, stdout, exit_code = handle:read()
print(stdout)
```

### HTTP requests

```lua
local fetch = require("cosmic.fetch")
local resp, err = fetch.get("https://api.example.com/data")
assert(resp, err)
print(resp.body)
```

### SQLite

```lua
local sqlite = require("cosmic.sqlite")
local db, err = sqlite.open("path/to/db.sqlite")
assert(db, err)
local rows = db:query("SELECT * FROM table WHERE id = ?", {42})
for _, row in ipairs(rows) do
  print(row.id, row.name)
end
db:close()
```

## Notes

- `arg[-1]` inside a running cosmic script is the path to the cosmic binary.
- teal (`.tl`) scripts are compiled to lua; use `make build` to compile before running.
- in sandboxed sessions, `AH_COSMIC` is always set; in unsandboxed sessions, rely on `o/bin/cosmic` or a system installation.
