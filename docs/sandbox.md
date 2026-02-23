# sandbox

source: `lib/ah/proxy.tl`, `lib/ah/sandbox.tl`

## overview

ah can sandbox agents by restricting network access, filesystem visibility, and
syscalls. these three mechanisms are independent and can be combined freely.

## flags

| flag | effect |
|------|--------|
| `--sandbox` | network sandbox: starts HTTP proxy, sets `https_proxy`, restricts outbound connections |
| `--unveil PATH:PERM` | filesystem restriction: limits what paths the agent can see (repeatable) |
| `--pledge` | syscall restriction: restricts which system calls the agent may use |

flags may be used independently or together.

## `--sandbox` mode

when `--sandbox` is passed, ah:

1. starts an HTTP CONNECT proxy on a unix socket (`/tmp/ah-sandbox-XXXXXX/proxy.sock`).
2. sets `https_proxy=unix://<socket>` for the agent process.
3. sets `AH_SANDBOX=1` in the child environment (enables both unveil and pledge in the child).

the agent can only reach hosts in the proxy allowlist.

`--allow-host H:P` adds entries to the allowlist (requires `--sandbox`).

## `--unveil` mode

when `--unveil PATH:PERM` is passed (without `--sandbox`), ah:

1. sets `AH_UNVEIL` in the child environment.
2. spawns a child process that applies `unveil` on startup, restricting filesystem visibility.

permissions are:
- `r` — read
- `w` — write
- `x` — execute
- `c` — create

## `--pledge` mode

when `--pledge` is passed (without `--sandbox`), ah:

1. sets `AH_PLEDGE=1` in the child environment.
2. spawns a child process that calls `pledge` on startup, restricting syscall access.

## combining flags

flags may be combined. for example:

```sh
# network sandbox only
ah --sandbox hello

# filesystem restriction only (no proxy)
ah --unveil /tmp:rwxc --unveil /usr:rx hello

# syscall restriction only
ah --pledge hello

# all three
ah --sandbox --unveil /data:r --pledge hello
```

## network proxy

`proxy.tl` implements an HTTP CONNECT proxy with a destination allowlist.

default allowlist: `api.anthropic.com:443`.

additional hosts are added via:
- `--allow-host HOST:PORT` CLI flag (repeatable, requires `--sandbox`).
- `AH_ALLOW_HOSTS` environment variable (comma-separated `host:port` entries).

the proxy resolves DNS, caches results, and relays TCP connections. all
non-allowed destinations are rejected.

## sandbox lifecycle

`sandbox.tl` manages sandbox setup and teardown:

1. `start_sandbox()`: forks a proxy child process, waits for socket readiness.
2. the child process runs with proxy env vars set.
3. `stop_sandbox()`: sends SIGTERM to proxy, cleans up socket and tmpdir.

## environment variables

| variable | purpose |
|----------|---------|
| `AH_SANDBOX` | set by supervisor when `--sandbox` is active; triggers unveil + pledge in child |
| `AH_UNVEIL` | comma-separated `path:perms` entries for filesystem restriction |
| `AH_PLEDGE` | set to `1` when `--pledge` is active without `--sandbox` |
| `AH_ALLOW_HOSTS` | additional `host:port` entries for proxy allowlist |
| `AH_PROTECT_DIRS` | colon-separated paths protected from write/edit |
| `https_proxy` | set automatically in sandbox mode to unix socket |
