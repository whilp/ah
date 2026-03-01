# sandbox

source: `lib/ah/proxy.tl`, `lib/ah/sandbox.tl`

## overview

ah can run agents in a sandbox that restricts network access, filesystem
visibility, and syscalls. these capabilities are decoupled — each flag can
be used independently.

## flags

| flag | effect |
|------|--------|
| `--sandbox` | network sandbox only: starts HTTP CONNECT proxy, sets `https_proxy` for agent |
| `--unveil PATH:PERM` | restrict filesystem visibility (repeatable) |
| `--pledge PROMISES` | restrict syscalls to given pledge promises |
| `--allow-host H:P` | add host:port to proxy allowlist (repeatable) |

flags can be combined freely. `--sandbox` no longer implies `--unveil` or
`--pledge`. `--unveil` and `--pledge` no longer require `--sandbox`.

## `--sandbox` mode

when `--sandbox` is passed, ah:

1. starts an HTTP CONNECT proxy on a unix socket (`/tmp/ah-sandbox-XXXXXX/proxy.sock`).
2. sets `https_proxy=unix://<socket>` for the agent process.
3. re-execs as a child process with `AH_SANDBOX=1` set.

the agent can only reach hosts in the proxy allowlist.

## `--unveil` mode

when `--unveil PATH:PERM` is passed (without `--sandbox`), ah applies
filesystem restrictions inline (no child process is spawned).

when combined with `--sandbox`, unveil is applied in the child process via
the `AH_UNVEIL` environment variable.

## `--pledge` mode

when `--pledge PROMISES` is passed (without `--sandbox`), ah applies syscall
restrictions inline (no child process is spawned).

when combined with `--sandbox`, pledge is applied in the child process via
the `AH_PLEDGE` environment variable.

## network proxy

`proxy.tl` implements an HTTP CONNECT proxy with a destination allowlist.

default allowlist: `api.anthropic.com:443`.

additional hosts are added via:
- `--allow-host HOST:PORT` CLI flag (repeatable).
- `AH_ALLOW_HOSTS` environment variable (comma-separated `host:port` entries).

`--allow-host` can be used without `--sandbox` (parsed freely; only takes
effect if a proxy is running).

the proxy resolves DNS, caches results, and relays TCP connections. all
non-allowed destinations are rejected.

## filesystem visibility

`--unveil PATH:PERM` restricts filesystem access. permissions are:
- `r` — read
- `w` — write
- `x` — execute
- `c` — create

## sandbox lifecycle

`sandbox.tl` manages sandbox setup and teardown:

1. `start_sandbox()`: forks a proxy child process, waits for socket readiness.
2. the child process runs with proxy env vars set.
3. `stop_sandbox()`: sends SIGTERM to proxy, cleans up socket and tmpdir.

## environment variables

| variable | purpose |
|----------|---------|
| `AH_SANDBOX` | set to `1` in the child process when `--sandbox` is used; triggers network proxy restrictions |
| `AH_UNVEIL` | comma-separated `path:perms` entries; triggers unveil even without `AH_SANDBOX` |
| `AH_PLEDGE` | pledge promises string; triggers pledge even without `AH_SANDBOX` |
| `AH_ALLOW_HOSTS` | additional `host:port` entries for proxy allowlist |
| `AH_LOG_LEVEL` | controls verbosity: `debug` enables proxy and sandbox lifecycle messages; defaults to `info` in CI, `debug` otherwise |
| `AH_PROTECT_DIRS` | colon-separated paths protected from write/edit |
| `AH_PROXY_VERBOSE` | legacy flag: `1` forces proxy logging regardless of `AH_LOG_LEVEL` |
| `https_proxy` | set automatically in sandbox mode to unix socket |
