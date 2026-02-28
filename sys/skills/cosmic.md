---
name: cosmic
description: Quick reference for cosmic-lua — language essentials, CLI commands, and project conventions
---

# cosmic

cosmic is the lua/teal runtime that powers `ah`. the `ah` binary IS the
cosmic executable. agents can invoke it directly via the `$AH_COSMIC`
environment variable.

## Invoking cosmic

`AH_COSMIC` is set in every `ah` session (sandboxed or not) and points to
the running binary:

```bash
# run a lua script
"$AH_COSMIC" script.lua

# run a teal script
"$AH_COSMIC" script.tl

# pass arguments
"$AH_COSMIC" script.lua arg1 arg2
```

## Shebang scripts

`cosmic` is not on `PATH`, so `#!/usr/bin/env cosmic` will not work. use a
shell wrapper shebang instead:

```lua
#!/usr/bin/env -S sh -c 'exec "$AH_COSMIC" "$0" "$@"'

-- your lua/teal code here
local json = require("cosmic.json")
print(json.encode({hello = "world"}))
```

make the script executable: `chmod +x script.lua`

then run it: `./script.lua`

## Key modules

| module | purpose |
|--------|---------|
| `cosmic.json` | JSON encode/decode |
| `cosmic.fs` | filesystem: read, write, mkdir, stat |
| `cosmic.io` | slurp/barf (read/write whole files) |
| `cosmic.child` | spawn subprocesses, capture output |
| `cosmic.sqlite` | embedded SQLite database |
| `cosmic.fetch` | HTTP requests |
| `cosmic.env` | environment variable access |
| `cosmic.sandbox` | unveil/pledge (OpenBSD-style sandboxing) |
| `cosmic.time` | time utilities |
| `cosmic.tty` | terminal detection and control |
| `cosmic.zip` | zip archive reading |
| `cosmic.embed` | access files embedded in the executable |

## Common patterns

### JSON

```lua
local json = require("cosmic.json")

-- decode
local data = json.decode('{"key": "value"}')
print(data.key)  -- "value"

-- encode
local s = json.encode({key = "value"})
print(s)  -- {"key":"value"}
```

### File I/O

```lua
local cio = require("cosmic.io")
local fs = require("cosmic.fs")

-- read entire file
local content = cio.slurp("path/to/file.txt")

-- write entire file
cio.barf("path/to/out.txt", "content")

-- list directory
local entries = fs.readdir(".")
for _, e in ipairs(entries) do print(e) end

-- make directories
fs.makedirs("a/b/c")
```

### Subprocesses

```lua
local child = require("cosmic.child")

-- run command and capture output
local handle, err = child.spawn({"git", "status"}, {})
if handle then
  local ok, stdout, code = handle:read()
  print(stdout)
end
```

### SQLite

```lua
local sqlite = require("cosmic.sqlite")

local db = sqlite.open("data.db")
db:exec("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, val TEXT)")
db:exec("INSERT INTO t (val) VALUES (?)", {"hello"})
local rows = db:query("SELECT * FROM t")
for _, row in ipairs(rows) do print(row.id, row.val) end
db:close()
```

## Teal type annotations

cosmic scripts can use teal (typed lua). use `.tl` extension for type-checked
files. type checking is separate from execution — `cosmic` runs both `.lua`
and `.tl` directly.

```teal
local json = require("cosmic.json")

local record Config
  name: string
  count: integer
end

local cfg: Config = json.decode(require("cosmic.io").slurp("config.json"))
print(cfg.name)
```

## Notes

- `$AH_COSMIC` is the canonical way to invoke cosmic from bash scripts
- the running executable path is `arg[-1]` from within lua/teal code
- embedded files (skills, prompts, etc.) are accessible via `/zip/` paths
