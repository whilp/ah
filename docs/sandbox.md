# sandbox

source: `lib/ah/proxy.tl`, `lib/ah/sandbox.tl`

## overview

ah can run agents in a sandbox that restricts network and filesystem access.

## `--sandbox` mode

when `--sandbox` is passed, ah:

1. starts an HTTP CONNECT proxy on a unix socket (`/tmp/ah-sandbox-XXXXXX/proxy.sock`).
2. sets `https_proxy=unix://<socket>` for the agent process.
3. applies `pledge` (restrict syscalls) and `unveil` (restrict filesystem visibility).

the agent can only reach hosts in the proxy allowlist.

## network proxy

`proxy.tl` implements an HTTP CONNECT proxy with a destination allowlist.

default allowlist: `api.anthropic.com:443`.

additional hosts are added via:
- `--allow-host HOST:PORT` CLI flag (repeatable).
- `AH_ALLOW_HOSTS` environment variable (comma-separated `host:port` entries).

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

## logging

ah writes progress and debug output to stderr.

log verbosity is controlled by the `AH_LOG_LEVEL` env var:

| value | behavior |
|-------|----------|
| `debug` | full output: sandbox lifecycle, proxy connections, phase details |
| `info` | quiet: only important messages (phase transitions, errors, outcomes) |

default: `info` when `CI` is set, `debug` otherwise. this means CI runs are
quiet by default and local runs are verbose by default.

to re-enable proxy connection logs (CONNECT, relay-done, byte counts) in any
mode, set `AH_PROXY_VERBOSE=1`.

## environment variables

| variable | purpose |
|----------|---------|
| `AH_ALLOW_HOSTS` | additional `host:port` entries for proxy allowlist |
| `AH_LOG_LEVEL` | log verbosity: `debug` (default locally) or `info` (default in CI) |
| `AH_PROTECT_DIRS` | colon-separated paths protected from write/edit |
| `AH_PROXY_VERBOSE` | set to `1` to enable proxy connection log lines |
| `https_proxy` | set automatically in sandbox mode to unix socket |
