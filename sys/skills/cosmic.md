---
name: cosmic
description: Use cosmic for Lua scripting from bash: run scripts, use modules, write shebangs.
---

# cosmic

cosmic is the Lua runtime embedded in `ah`. the `$COSMIC` env var points to the
`ah` binary, which doubles as a `cosmic` executable. use it to write and run Lua
scripts from the bash tool.

## Running scripts

```bash
# run a Lua script
"$COSMIC" script.lua

# run inline
"$COSMIC" - <<'EOF'
print("hello from cosmic")
EOF

# check the path
echo "$COSMIC"
```

`$COSMIC` is always set in the agent environment. do not assume `cosmic` is on `PATH`
— use `"$COSMIC"` directly.

## Shebangs

`#!/usr/bin/env cosmic` won't work unless `cosmic` is on PATH. use this pattern instead:

```lua
#!/bin/sh
-- 2>/dev/null; exec "$COSMIC" "$0" "$@"; exit 1
-- rest of your Lua script here
print("hello")
```

or write a plain `.lua` file and invoke it with `"$COSMIC" script.lua`.

## Key modules

| module | purpose |
|--------|---------|
| `cosmic.json` | JSON encode/decode |
| `cosmic.fs` | filesystem: read, write, stat, mkdir, glob |
| `cosmic.io` | slurp/barf (read/write entire files) |
| `cosmic.child` | spawn subprocesses, capture output |
| `cosmic.sqlite` | SQLite database access |
| `cosmic.fetch` | HTTP client |
| `cosmic.net` | low-level networking |
| `cosmic.env` | environment variable helpers |
| `cosmic.sandbox` | pledge/unveil capability restriction |
| `cosmic.proc` | process control: exec, fork, setrlimit |
| `cosmic.tty` | terminal detection |
| `cosmic.time` | sleep, timestamps |

## Examples

### Parse JSON

```lua
local json = require("cosmic.json")
local data = json.decode('{"key": "value"}')
print(data.key)  -- value
local encoded = json.encode({name = "ah", version = 1})
print(encoded)
```

### Read and write files

```lua
local cio = require("cosmic.io")
local fs = require("cosmic.fs")

-- read entire file
local content = cio.slurp("path/to/file.txt")

-- write entire file
cio.barf("path/to/out.txt", "hello\n")

-- list directory
local entries = fs.readdir(".")
for _, e in ipairs(entries) do print(e) end
```

### Run a subprocess

```lua
local child = require("cosmic.child")
local handle, err = child.spawn({"git", "log", "--oneline", "-5"}, {})
if handle then
  local ok, stdout, exit = handle:read()
  print(stdout)
end
```

### Script from bash tool

```bash
"$COSMIC" - <<'EOF'
local json = require("cosmic.json")
local result = json.encode({status = "ok", count = 42})
print(result)
EOF
```

## Notes

- `$COSMIC` is set automatically; no installation required.
- cosmic uses Lua 5.4 syntax with some extensions.
- teal (`.tl`) files require compilation before running; use plain `.lua` for scripts.
- scripts run with the same filesystem access as the agent (sandboxed or not).
